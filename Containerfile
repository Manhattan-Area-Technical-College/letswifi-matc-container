#Manhattan Tech's Container build of LetsWifi for our eduroam deployment. 
#Builds are multistage
#Stage 1 Build
FROM registry.access.redhat.com/ubi10/ubi:10.0 AS builder
    
ARG LETSWIFI_VERSION=v2.0.0-beta5
ARG LETSWIFI_SHA256=b6f0d50a991dc4491adf324d0535d409f020d3c109b89fde117755c33e721d26
ARG SSP_VERSION=2.5.2
ARG SSP_SHA256=1394883cc15fb532b9cbac899377caac72163aaab964c0c67a793a69142a8902

RUN dnf install -y php php-xml php-mbstring tar unzip git && dnf clean all
COPY --from=docker.io/library/composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /build

RUN <<EOF bash
    set -euxo pipefail
    curl -sSL "https://github.com/geteduroam/letswifi-portal/archive/refs/tags/${LETSWIFI_VERSION}.tar.gz" -o "${LETSWIFI_VERSION}.tar.gz"
    echo "${LETSWIFI_SHA256} ${LETSWIFI_VERSION}.tar.gz" | sha256sum -c -
    mkdir letswifi-portal
    tar xz --strip-components=1 -C letswifi-portal -f "${LETSWIFI_VERSION}.tar.gz"
    rm "${LETSWIFI_VERSION}.tar.gz"
    cd letswifi-portal
    if [[ ! -f composer.lock ]]; then
        echo "ERROR: composer.lock is missing from the tarball." >&2
        echo "       This means composer will resolve dependencies freely and we will get supplychained" >&2
        echo "       and that makes cybersecurity very sad. So the build fails instead" >&2
        exit 1
    fi
    composer install --no-dev --no-interaction --optimize-autoloader --no-progress
EOF

RUN <<EOF bash
    set -euxo pipefail
    curl -sSL "https://github.com/simplesamlphp/simplesamlphp/releases/download/v${SSP_VERSION}/simplesamlphp-${SSP_VERSION}-full.tar.gz" -o ssp.tar.gz
    echo "${SSP_SHA256}  ssp.tar.gz" | sha256sum -c -
    mkdir simplesamlphp
    tar xz --strip-components=1 -C simplesamlphp -f ssp.tar.gz
    rm ssp.tar.gz
EOF

#Stage 2 For real this time
FROM registry.access.redhat.com/ubi10/ubi-init:10.0

RUN <<EOF bash
    set -euxo pipefail
    dnf install -y httpd mod_ssl php php-fpm php-xml php-mbstring php-pdo php-mysqlnd sqlite cronie php-curl openssl
    dnf clean all
EOF

RUN systemctl enable httpd php-fpm crond

COPY --from=builder /build/letswifi-portal /usr/local/share/letswifi-portal
COPY --from=builder /build/simplesamlphp   /usr/local/share/simplesamlphp

RUN <<EOF bash
    set -euxo pipefail
    ln -s /etc/letswifi     /usr/local/share/letswifi-portal/config
    ln -s /var/lib/letswifi /usr/local/share/letswifi-portal/var
    mv /usr/local/share/simplesamlphp/config /usr/local/share/simplesamlphp/config-dist
    rm -rf /usr/local/share/simplesamlphp/metadata
    ln -s /etc/simplesamlphp /usr/local/share/simplesamlphp/config
EOF

COPY httpd-letswifi.conf  /etc/httpd/conf.d/letswifi.conf

# With TLS terminated outside the container, PHP sees SERVER_PORT=80 and the portal/SimpleSAMLphp append ":80" to the URLs
COPY forwarded-port.php     /usr/local/share/letswifi-portal/forwarded-port.php
COPY php-forwarded-port.ini /etc/php.d/90-forwarded-port.ini

COPY entrypoint.sh        /usr/local/bin/entrypoint.sh
COPY letswifi-gen-crl     /usr/local/bin/letswifi-gen-crl
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/letswifi-gen-crl

COPY letswifi-crl.service letswifi-crl.timer /etc/systemd/system/
COPY letswifi-metarefresh.service letswifi-metarefresh.timer /etc/systemd/system/
RUN systemctl enable letswifi-crl.timer letswifi-metarefresh.timer

RUN <<EOF bash
    set -euxo pipefail
    mkdir -p /etc/letswifi/trust /etc/simplesamlphp /var/lib/letswifi \
             /var/lib/simplesamlphp/data /var/cache/simplesamlphp \
             /var/www/letswifi-crl
    chown -R apache:apache /var/lib/letswifi /var/lib/simplesamlphp \
                           /var/cache/simplesamlphp /var/www/letswifi-crl
EOF

VOLUME /var/lib/letswifi
VOLUME /etc/letswifi
VOLUME /etc/simplesamlphp

EXPOSE 80 443

CMD ["/usr/local/bin/entrypoint.sh"]

# vim: set filetype=dockerfile expandtab shiftwidth=4 tabstop=4 softtabstop=4:
