ARG PHP_VERSION=8.3
ARG HOST_IP=127.0.0.1

FROM php:${PHP_VERSION}-apache

ARG TARGETARCH
ENV ILIAS_DEVMODE=1
ARG NODE_VERSION

RUN set -e \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        cron \
        curl \
        ca-certificates \
        ghostscript \
        imagemagick \
        libmagickwand-dev \
        ffmpeg \
        libldap-common \
        libldap-dev \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
        libxslt-dev \
        libzip-dev \
        mariadb-client \
        pwgen \
        unzip \
        vim \
        zip \
        xfonts-75dpi \
        xfonts-base \
        default-jdk \
        maven \
    && rm -rf /var/lib/apt/* /var/cache/apt/*

RUN sed -i '/disable ghostscript format types/,+6d' /etc/ImageMagick-7/policy.xml

RUN docker-php-ext-configure ldap --with-libdir=lib/$(uname -m)-linux-gnu/ \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install \
        gd \
        ldap \
        mysqli \
        pdo \
        pdo_mysql \
        soap \
        xsl \
        zip \
    && pecl install \
        channel://pecl.php.net/xmlrpc-1.0.0RC3 \
        imagick \
    && docker-php-ext-enable \
        xmlrpc \
        imagick

RUN a2enmod \
    expires \
    headers \
    rewrite

RUN curl -sS https://getcomposer.org/installer \
    | php -- --2 --install-dir=/usr/local/bin --filename=composer

ENV ILIAS_WWW_PATH=/var/www/html
ENV ILIAS_DATA_PATH=/var/www/html/public/data
ENV ILIAS_ILIASDATA_PATH=/var/iliasdata/ilias

RUN mkdir -p ${ILIAS_ILIASDATA_PATH} \
    && chown www-data:root ${ILIAS_ILIASDATA_PATH} \
    && chmod 775 ${ILIAS_ILIASDATA_PATH}
VOLUME ${ILIAS_ILIASDATA_PATH}

RUN mkdir -p ${ILIAS_DATA_PATH} \
    && chown www-data:root ${ILIAS_DATA_PATH} \
    && chmod 775 ${ILIAS_DATA_PATH}
VOLUME ${ILIAS_DATA_PATH}

COPY docker-ilias-entrypoint /usr/local/bin/docker-ilias-entrypoint

RUN chmod +x /usr/local/bin/docker-ilias-entrypoint


RUN sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html/public|g' /etc/apache2/sites-enabled/000-default.conf

RUN case ${TARGETARCH} in amd64) NODE_ARCH=x64 ;; arm64) NODE_ARCH=arm64 ;; *) exit 1 ;; esac \
    && curl -o /opt/node.tar.xz -SL https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz \
    && mkdir /opt/node \
    && tar -xJf /opt/node.tar.xz -C /opt/node --strip-components=1 --no-same-owner \
    && rm /opt/node.tar.xz \
    && ln -s /opt/node/bin/node /usr/local/bin/node \
    && ln -s /opt/node/bin/npm /usr/local/bin/npm

RUN npm install -g sass

RUN pecl install xdebug

RUN echo "zend_extension=$(find /usr/local/lib/php/extensions/ -name xdebug.so)\n\
xdebug.mode = develop,debug,profile\n\
xdebug.discover_client_host = false\n\
xdebug.client_port = 9003\n\
xdebug.log = /var/log/xdebug.log\n\
xdebug.start_with_request = yes\n\
xdebug.output_dir = /var/iliasdata/ilias\n\
xdebug.client_host = ${HOST_IP}"\
> /usr/local/etc/php/conf.d/xdebug.ini \
    && touch /var/log/xdebug.log \
    && chown www-data /var/log/xdebug.log

RUN echo "error_reporting = E_ALL & ~E_NOTICE & ~E_WARNING & ~E_STRICT\n\
display_errors = On" \
> /usr/local/etc/php/conf.d/ilias-dev.ini

ENTRYPOINT ["docker-ilias-entrypoint"]
CMD ["apache2-foreground"]
EXPOSE 80
