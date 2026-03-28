#!/usr/bin/env bash

set -euo pipefail

if [ $# -lt 1 ]; then
	echo "Usage: $0 <ilias_major_version> [<ilias_dir_name>]"
	echo "Example: $0 9"
	exit 1
fi

ILIAS_VERSION="$1"

BASE_DIR="$HOME/code"
INSTANCES_FILE="$BASE_DIR/ilias-instances"
# If $2 is provided, use it as directory name suffix, otherwise default to version-based naming
if [ $# -ge 2 ]; then
	IL_DIR="$BASE_DIR/$2"
else
	IL_DIR="$BASE_DIR/il_${ILIAS_VERSION}"
fi

ILIASDATA_DIR="$IL_DIR/iliasdata"
PROJECT_DIR="$IL_DIR"
REPO_DIR="$IL_DIR/ilias_${ILIAS_VERSION}"
DOCKER_COMPOSE_FILE="$IL_DIR/docker-compose.yml"

# Map major version to srsolutions/ilias-dev tag
get_image_tag() {
	local ver="$1"
	case "$ver" in
	8) echo "8-php8.0-apache" ;;
	9) echo "9-php8.2-apache" ;;
	10) echo "10-php8.3-apache" ;;
	11) echo "11-beta-php8.4-apache" ;;
	12) echo "11-beta-php8.4-apache" ;; # 12 uses 11-beta image
	*)
		echo "Unsupported ILIAS version '$ver'" >&2
		exit 1
		;;
	esac
}

IMAGE_TAG="$(get_image_tag "$ILIAS_VERSION")"
IMAGE_NAME="srsolutions/ilias-dev:${IMAGE_TAG}"

mkdir -p "$BASE_DIR"
[ -f "$INSTANCES_FILE" ] || touch "$INSTANCES_FILE"

# Determine next free ports from last line in ilias-instances
LAST_LINE="$(tail -n 1 "$INSTANCES_FILE" || true)"
if [ -z "$LAST_LINE" ]; then
	APP_PORT=8500
	DB_PORT=3500
else
	LAST_APP_PORT="$(echo "$LAST_LINE" | awk -F':' '{print $2}')"
	LAST_DB_PORT="$(echo "$LAST_LINE" | awk -F':' '{print $3}')"
	if ! [[ "$LAST_APP_PORT" =~ ^[0-9]+$ ]] || ! [[ "$LAST_DB_PORT" =~ ^[0-9]+$ ]]; then
		echo "Warning: Could not parse last line of $INSTANCES_FILE: '$LAST_LINE'"
		echo "Falling back to default ports 8500/3500."
		APP_PORT=8500
		DB_PORT=3500
	else
		APP_PORT=$((LAST_APP_PORT + 1))
		DB_PORT=$((LAST_DB_PORT + 1))
	fi
fi

echo "Using ports: HTTP ${APP_PORT}, DB ${DB_PORT}"

# Prepare data directory
mkdir -p "$ILIASDATA_DIR/ilias"
sudo chown -R 33:33 "$ILIASDATA_DIR"

# Prepare project directory
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Clone repo if needed
if [ ! -d "$REPO_DIR/.git" ]; then
	echo "Cloning ILIAS repository into $REPO_DIR ..."
	git clone git@github.com:23b00t/ILIAS.git "$REPO_DIR"
else
	echo "Repository $REPO_DIR already exists, skipping clone."
fi

cd "$REPO_DIR"
mkdir -p "$REPO_DIR/public/Customizing/global/plugins"

# Try to checkout release_<version>, fall back to default branch if not found
if git checkout "release_${ILIAS_VERSION}" >/dev/null 2>&1; then
	echo "Checked out branch/tag release_${ILIAS_VERSION}."
else
	echo "Note: Branch/Tag release_${ILIAS_VERSION} not found, staying on default branch."
fi

cd "$PROJECT_DIR"

sudo rm -f ${REPO_DIR}/ilias.ini.php

# Generate docker-compose.yml with AUTO_SETUP enabled for first run
cat >"$DOCKER_COMPOSE_FILE" <<EOF
services:
  ilias:
    image: ${IMAGE_NAME}
    ports:
      - ${APP_PORT}:80
    depends_on:
      - mysql
    volumes:
      - ./ilias_${ILIAS_VERSION}:/var/www/html
      - ./iliasdata:/var/iliasdata
    dns:
      - 8.8.8.8
      - 1.1.1.1
    environment:
      - ILIAS_DB_HOST=mysql
      - ILIAS_DB_USER=ilias
      - ILIAS_DB_PASSWORD=trash
      - ILIAS_DB_NAME=ilias
      - ILIAS_DB_PORT=3306
      - ILIAS_DATA_PATH=/var/iliasdata
      - ILIAS_DEVMODE=1
      - ILIAS_HTTP_PATH=http://10.0.0.15
      - ILIAS_ROOT_PASSWORD=trash
      # First time
      - ILIAS_AUTO_SETUP=1
      - ILIAS_DUMP_AUTOLOAD=1
      - ILIAS_CLIENT_NAME=default
  mysql:
    image: mariadb
    ports:
      - "${DB_PORT}:3306"
    command:
      - --character-set-server=utf8
      - --collation-server=utf8_general_ci
    environment:
      - MYSQL_ROOT_PASSWORD=trash
      - MYSQL_DATABASE=ilias
      - MYSQL_USER=ilias
      - MYSQL_PASSWORD=trash
EOF

# Append human-readable instance info
echo "${IL_DIR}:${APP_PORT}:${DB_PORT}" >>"$INSTANCES_FILE"

sudo chown -R 33:www-data ${REPO_DIR}
sudo chmod -R 775 ${REPO_DIR}

# Pre-populate node_modules (npm clean-install --ignore-scripts) and vendor via one-off container
echo "Pre-populating node_modules and vendor via one-off container in ${REPO_DIR} ..."
sudo docker run --rm \
  -v "$REPO_DIR":/var/www/html \
  -w /var/www/html \
  "$IMAGE_NAME" \
  bash -lc '
    set -e
    if [ -f package.json ]; then
      echo "Running: npm clean-install --ignore-scripts ..."
      npm clean-install --ignore-scripts
    else
      echo "No package.json found, skipping npm clean-install."
    fi
    echo "Running: composer install --no-interaction --prefer-dist ..."
    composer install --no-interaction --prefer-dist
  ' || { echo "ERROR: pre-build (npm/composer) failed"; exit 1; }

echo "Starting Docker Compose (detached, with AUTO_SETUP) in $PROJECT_DIR ..."
cd "$PROJECT_DIR"
sudo docker compose up -d

# Determine container ID for the 'ilias' service in this project
ILIASCID="$(sudo docker compose ps -q ilias)"
if [ -z "$ILIASCID" ]; then
	echo "Error: Could not determine ILIAS container ID. Aborting."
	exit 1
fi
echo "ILIAS container ID: $ILIASCID"

# Wait for ILIAS auto-setup to complete by watching logs
echo "Waiting for 'ILIAS installed successfully!' in ilias logs ..."
MAX_WAIT_SECONDS=600
SLEEP_INTERVAL=10
ELAPSED=0
FOUND=0

while [ "$ELAPSED" -lt "$MAX_WAIT_SECONDS" ]; do
	if sudo docker compose logs ilias 2>&1 | grep -q "ILIAS installed successfully!"; then
		FOUND=1
		break
	fi
	sleep "$SLEEP_INTERVAL"
	ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
	echo "  ... still waiting (${ELAPSED}s elapsed)"
done

if [ "$FOUND" -ne 1 ]; then
	echo "Warning: Did not find 'ILIAS installed successfully!' in logs within ${MAX_WAIT_SECONDS}s."
	echo "You may want to inspect the logs manually: sudo docker compose logs ilias"
else
	echo "ILIAS auto-setup completed."
fi

echo "Patching xdebug config and installing vim inside running ILIAS container ..."

# Write custom xdebug.ini with client_host set to host IP inside the running container
HOST_IP="$(hostname -I | awk '{print $1}')"

echo "Writing custom xdebug.ini (client_host=${HOST_IP}) inside running ILIAS container ..."

sudo docker exec "$ILIASCID" bash -lc "cat >/usr/local/etc/php/conf.d/xdebug.ini" <<EOF
zend_extension=/usr/local/lib/php/extensions/no-debug-non-zts-20230831/xdebug.so
xdebug.mode = develop,debug,profile
xdebug.discover_client_host = false
xdebug.client_port = 9003
xdebug.log = /var/log/xdebug.log
xdebug.start_with_request = yes
xdebug.output_dir = /var/iliasdata/ilias
xdebug.client_host = ${HOST_IP}
EOF

# Install vim
sudo docker exec "$ILIASCID" bash -lc \
	'apt-get update && apt-get install -y --no-install-recommends vim && rm -rf /var/lib/apt/lists/*' ||
	echo "Warning: Failed to install vim"

# Restart Apache to apply xdebug changes
sudo docker exec "$ILIASCID" apache2ctl -k restart || echo "Warning: Failed to restart Apache"

echo "Commenting out AUTO_SETUP and DUMP_AUTOLOAD in docker-compose.yml ..."

# Comment out AUTO_SETUP and DUMP_AUTOLOAD lines for subsequent runs
sed -i \
	-e 's/^\(\s*-\s*ILIAS_AUTO_SETUP=1\)/# \1/' \
	-e 's/^\(\s*-\s*ILIAS_DUMP_AUTOLOAD=1\)/# \1/' \
	"$DOCKER_COMPOSE_FILE"

echo "Done."
echo "ILIAS should now be available at http://${HOST_IP}:${APP_PORT}"
echo "Containers will keep running. Subsequent 'docker compose up' calls will not re-run AUTO_SETUP."
