#!/usr/bin/env bash

set -euo pipefail

if [ $# -lt 1 ]; then
	echo "Usage: $0 <ilias_major_version> [<ilias_dir_name>]"
	echo "Example: $0 9"
	exit 1
fi

ILIAS_VERSION="$1"

SCRIPT_ROOT="$(pwd)"
BASE_DIR="$HOME/code"
INSTANCES_FILE="$BASE_DIR/ilias-instances"
# If $2 is provided, use it as directory name suffix, otherwise default to version-based naming
if [ $# -ge 2 ]; then
	IL_DIR="$BASE_DIR/$2"
else
	IL_DIR="$BASE_DIR/il_${ILIAS_VERSION}"
fi

# Check if directory already exists and ask user to confirm before proceeding
if [ -d "$IL_DIR" ]; then
	echo "Directory $IL_DIR already exists. Do you want to proceed and potentially overwrite changes? (y/N)"
	read -r answer
	if [[ ! "$answer" =~ ^[Yy]$ ]]; then
		echo "Aborting."
		exit 1
	fi
fi

ILIASDATA_DIR="$IL_DIR/iliasdata"
PROJECT_DIR="$IL_DIR"
REPO_DIR="$IL_DIR/ilias_${ILIAS_VERSION}"
DOCKER_COMPOSE_FILE="$IL_DIR/docker-compose.yml"
HOST_IP="$(hostname -I | awk '{print $1}')"
DB_USER="ilias"
DB_PASSWD="trash"
DB_NAME="ilias"

# Map major version to srsolutions/ilias-dev tag
get_php_version() {
	local ver="$1"
	case "$ver" in
	10) echo "8.3" ;;
	11) echo "8.4" ;;
	12) echo "8.4" ;;
	*)
		echo "Unsupported ILIAS version '$ver'" >&2
		exit 1
		;;
	esac
}

# Map major version to a Node.js version compatible with that ILIAS branch
get_node_version() {
	local ver="$1"
	case "$ver" in
	10) echo "20.10.0" ;;
	11) echo "20.10.0" ;;
	12) echo "22.18.0" ;;
	*)
		echo "Unsupported ILIAS version '$ver'" >&2
		exit 1
		;;
	esac
}


PHP_VERSION="$(get_php_version "$ILIAS_VERSION")"
NODE_VERSION="$(get_node_version "$ILIAS_VERSION")"


mkdir -p "$BASE_DIR"
[ -f "$INSTANCES_FILE" ] || touch "$INSTANCES_FILE"

# Determine next free ports from last line in ilias-instances
LAST_LINE="$(tail -n 1 "$INSTANCES_FILE" || true)"
if [ -z "$LAST_LINE" ]; then
	APP_PORT=8500
	DB_PORT=3500
	MAILPIT_PORT=4500
else
	LAST_APP_PORT="$(echo "$LAST_LINE" | awk -F':' '{print $2}')"
	LAST_DB_PORT="$(echo "$LAST_LINE" | awk -F':' '{print $3}')"
	LAST_MAILPIT_PORT="$(echo "$LAST_LINE" | awk -F':' '{print $4}')"
	if ! [[ "$LAST_APP_PORT" =~ ^[0-9]+$ ]] || ! [[ "$LAST_DB_PORT" =~ ^[0-9]+$ ]] || ! [[ "$LAST_MAILPIT_PORT" =~ ^[0-9]+$ ]]; then
		echo "Warning: Could not parse last line of $INSTANCES_FILE: '$LAST_LINE'"
		echo "Falling back to default ports 8500/3500/4500."
		APP_PORT=8500
		DB_PORT=3500
		MAILPIT_PORT=4500
	else
		APP_PORT=$((LAST_APP_PORT + 1))
		DB_PORT=$((LAST_DB_PORT + 1))
		MAILPIT_PORT=$((LAST_MAILPIT_PORT + 1))
	fi
fi

echo "Using ports: HTTP ${APP_PORT}, DB ${DB_PORT}, Mailpit ${MAILPIT_PORT}"

# Prepare data directory
mkdir -p "$ILIASDATA_DIR/ilias"
sudo chown -R 33:33 "$ILIASDATA_DIR"

# Prepare project directory
mkdir -p "$PROJECT_DIR"

# Copy the local Dockerfile (from the directory where this script is located) into PROJECT_DIR
if [ -f "$SCRIPT_ROOT/resources/Dockerfile" ]; then
	cp -f "$SCRIPT_ROOT/resources/Dockerfile" "$PROJECT_DIR/Dockerfile"
else
	echo "Error: Dockerfile not found in SCRIPT_ROOT: $SCRIPT_ROOT/resources/Dockerfile" >&2
	exit 1
fi

# Copy the local docker-ilias-entrypoint from SCRIPT_ROOT into PROJECT_DIR 
if [ -f "$SCRIPT_ROOT/resources/docker-ilias-entrypoint" ]; then
	cp -f "$SCRIPT_ROOT/resources/docker-ilias-entrypoint" "$PROJECT_DIR/docker-ilias-entrypoint"
else
	echo "Error: docker-ilias-entrypoint not found in SCRIPT_ROOT: $SCRIPT_ROOT/resources/docker-ilias-entrypoint" >&2
	exit 1
fi

cd "$PROJECT_DIR"

# Clone repo if needed
if [ ! -d "$REPO_DIR/.git" ]; then
	echo "Cloning ILIAS repository into $REPO_DIR ..."
	git clone git@github.com:23b00t/ILIAS.git "$REPO_DIR"
else
	echo "Repository $REPO_DIR already exists, skipping clone."
fi

cd "$REPO_DIR"
git fetch origin
mkdir -p "$REPO_DIR/public/Customizing/global/plugins"

# Try to checkout release_<version>, fall back to default branch if not found
if git checkout "release_${ILIAS_VERSION}" >/dev/null 2>&1; then
	echo "Checked out branch/tag release_${ILIAS_VERSION}."
else
  if git checkout trunk >/dev/null 2>&1; then
    echo "Branch/tag release_${ILIAS_VERSION} not found, checked out trunk instead."
  else
    echo "Error: Could not checkout release_${ILIAS_VERSION} or trunk. Please check your repository." >&2
    exit 1
  fi
fi

cd "$PROJECT_DIR"

sudo rm -f ${REPO_DIR}/ilias.ini.php

# Generate docker-compose.yml with AUTO_SETUP enabled for first run
cat >"$DOCKER_COMPOSE_FILE" <<EOF
services:
  ilias:
    build:
      context: .
      dockerfile: ./Dockerfile

      args:
        PHP_VERSION: "${PHP_VERSION}"
        HOST_IP: "${HOST_IP}"
        NODE_VERSION: "${NODE_VERSION}"
    ports:
      - "${APP_PORT}:80"
    depends_on:
      mysql:
        condition: service_started
    volumes:
      - ./ilias_${ILIAS_VERSION}:/var/www/html
      - ./iliasdata:/var/iliasdata
    dns:
      - 8.8.8.8
      - 1.1.1.1
    environment:
      - ILIAS_DB_HOST=mysql
      - ILIAS_DB_USER=${DB_USER}
      - ILIAS_DB_PASSWORD=${DB_PASSWD}
      - ILIAS_DB_NAME=${DB_NAME}
      - ILIAS_DB_PORT=3306
      - ILIAS_DATA_PATH=/var/iliasdata
      - ILIAS_DEVMODE=1
      - ILIAS_HTTP_PATH=http://${HOST_IP}:${APP_PORT}
      - ILIAS_ROOT_PASSWORD=trash
      - ILIAS_AUTO_SETUP=1
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
      - MYSQL_DATABASE=${DB_NAME}
      - MYSQL_USER=${DB_USER}
      - MYSQL_PASSWORD=${DB_PASSWD}

  mailpit:
    image: axllent/mailpit
    volumes:
      - ./mailer:/data
    ports:
      - "${MAILPIT_PORT}:8025"
    environment:
      MP_DATABASE: /data/mailpit.db
      MP_SMTP_AUTH_ACCEPT_ANY: 1
      MP_SMTP_AUTH_ALLOW_INSECURE: 1
    networks:
      - default
EOF

# Append human-readable instance info
echo "${IL_DIR}:${APP_PORT}:${DB_PORT}:${MAILPIT_PORT}" >>"$INSTANCES_FILE"

# Pre-populate node_modules (npm clean-install --ignore-scripts) and vendor via one-off container
echo "Pre-populating node_modules and vendor via one-off container in ${REPO_DIR} ..."
(
	cd "$PROJECT_DIR"
	sudo docker compose run --rm --no-deps \
		--build \
		-w /var/www/html \
		ilias \
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
      '
) || {
	echo "ERROR: pre-build (npm/composer) failed"
	exit 1
}

sudo chown -R 33:33 "${REPO_DIR}"

# Set ACLs to allow user to edit files created by www-data in the repo directory (if setfacl is available)
if command -v setfacl >/dev/null 2>&1; then
  sudo setfacl -R -m u:"$USER":rwX "$REPO_DIR"
  sudo setfacl -d -m u:"$USER":rwX "$REPO_DIR"
fi

echo "Starting Docker Compose (detached, with AUTO_SETUP) in $PROJECT_DIR ..."
cd "$PROJECT_DIR"

# Remove any existing containers/volumes for this project to ensure a clean start (ignore errors if they don't exist)
sudo docker compose down -v || true
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

echo "ILIAS should now be available at http://${HOST_IP}:${APP_PORT}"

# Resolve script directory (where resources/ lives), independent of current working directory
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "Copying phpcs and phpstan configs to $IL_DIR ..."
cp "$SCRIPT_ROOT/resources/phpcs.xml" "$IL_DIR/phpcs.xml"
cp "$SCRIPT_ROOT/resources/phpstan.neon" "$IL_DIR/phpstan.neon"
cp "$SCRIPT_ROOT/resources/constants.php" "$IL_DIR/constants.php"
echo "done."

echo "Setup direnv for $IL_DIR ..."
cat >"$IL_DIR/.envrc" <<EOF
# Set PHP version
PATH_add /home/user/bin/php${PHP_VERSION}

# Set DBUI URL
export DBUI_URL="mariadb://${DB_USER}:${DB_PASSWD}@127.0.0.1:${DB_PORT}/${DB_NAME}"
EOF
echo "done."
