#!/bin/sh
set -e

APP=/usr/local/share/letswifi-portal
SSP=/usr/local/share/simplesamlphp

CERT=/etc/pki/tls/certs/letswifi.crt
KEY=/etc/pki/tls/private/letswifi.key
CA=/etc/pki/tls/certs/ca.crt
SSL_CONF=/etc/httpd/conf.d/letswifi-ssl.conf

# Escape characters that are special in a sed replacement string (delimiter @).
sed_escape() { printf '%s' "$1" | sed 's/[\\&@]/\\&/g'; }

# Escape characters that are special inside a PHP single-quoted string.
php_escape() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }

# Fail fast on the one env var httpd needs at every start (not just first run).
: "${LETSWIFI_FQDN:?LETSWIFI_FQDN is required (the public hostname, e.g. wifi.example.edu)}"

# ── System crypto policy ──────────────────────────────────────────────────────
# Optional: CRYPTO_POLICY=DEFAULT|FUTURE|NEXT|FIPS
#   DEFAULT  TLS 1.2+, strong ciphers          (UBI 10 built-in default)
#   FUTURE   TLS 1.3 only, stricter key sizes  (recommended if all clients support it)
#   NEXT     TLS 1.3 only + additional restrictions (bleeding edge)
#   FIPS     FIPS 140 approved algorithms only  (note: full FIPS compliance also
#            requires fips=1 on the host kernel — this sets the algorithm policy only)
if [ -n "${CRYPTO_POLICY:-}" ]; then
    case "$CRYPTO_POLICY" in
        DEFAULT|FUTURE|NEXT|FIPS)
            echo "letswifi: setting system crypto policy to ${CRYPTO_POLICY}"
            update-crypto-policies --set "$CRYPTO_POLICY"
            ;;
        LEGACY)
            echo "letswifi: WARNING: LEGACY crypto policy enables weak ciphers and is not recommended." >&2
            echo "letswifi: WARNING: Use DEFAULT or FUTURE unless you have very old clients that require it." >&2
            update-crypto-policies --set LEGACY
            ;;
        *)
            echo "letswifi: ERROR: unknown CRYPTO_POLICY value '${CRYPTO_POLICY}'." >&2
            echo "letswifi:        valid values: DEFAULT, FUTURE, NEXT, FIPS" >&2
            exit 1
            ;;
    esac
fi

# ── letswifi config (first run only) ─────────────────────────────────────────
if [ ! -f /etc/letswifi/letswifi.conf.php ]; then
    echo "letswifi: first run — initialising letswifi config"
    cp -a "$APP"/config-dist/. /etc/letswifi/

    DSN="sqlite:/var/lib/letswifi/letswifi.sqlite"
    sed -e "s@^\(\s*'dsn'\).*\$@\1 => '$(sed_escape "${DSN}")',@" \
        -e "s@^\(\s*'username'\).*\$@\1 => null,@" \
        -e "s@^\(\s*'password'\).*\$@\1 => null,@" \
        /etc/letswifi/database.conf.dist-sqlite.php > /etc/letswifi/database.conf.php

    # Admin users: comma-separated user IDs or eduPersonAffiliation values.
    # Checked against the SAML-authenticated user's ID and affiliations at login.
    _admins_php=""
    if [ -n "${LETSWIFI_ADMIN_USERS:-}" ]; then
        _old_ifs="$IFS"; IFS=','
        for _admin in $LETSWIFI_ADMIN_USERS; do
            IFS="$_old_ifs"
            _admin="$(printf '%s' "$_admin" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [ -z "$_admin" ] && { IFS=','; continue; }
            _escaped="$(php_escape "$_admin")"
            if [ -z "$_admins_php" ]; then
                _admins_php="'${_escaped}'"
            else
                _admins_php="${_admins_php}, '${_escaped}'"
            fi
            IFS=','
        done
        IFS="$_old_ifs"
    fi
    awk -v admins="$_admins_php" '
        /'"'"'admins'"'"' *=> *\[/ {
            printf "    '"'"'admins'"'"' => [%s],\n", admins
            in_block = 1; next
        }
        in_block && /^[[:space:]]*\],?[[:space:]]*$/ { in_block = 0; next }
        in_block { next }
        { print }
    ' /etc/letswifi/letswifi.conf.php > /tmp/lw-conf.tmp \
        && mv /tmp/lw-conf.tmp /etc/letswifi/letswifi.conf.php

    # User identity attribute: which SAML/OIDC attribute to use as the user identity
    # embedded in each issued device cert.  null = SSP NameID (typically UPN from Entra).
    if [ -n "${LETSWIFI_USER_ID_ATTRIBUTE:-}" ]; then
        _uid_escaped="$(php_escape "$LETSWIFI_USER_ID_ATTRIBUTE")"
        sed -i "s/'userIdAttribute' *=> *null/'userIdAttribute' => '${_uid_escaped}'/" \
            /etc/letswifi/letswifi.conf.php
    fi

    # Affiliation attribute: which SAML/OIDC attribute carries the user's affiliations.
    # Used for realm assignment and admin scope checks.  Default: eduPersonAffiliation.
    if [ -n "${LETSWIFI_AFFILIATION_ATTRIBUTE:-}" ]; then
        _aff_escaped="$(php_escape "$LETSWIFI_AFFILIATION_ATTRIBUTE")"
        sed -i "s/'affiliationAttribute' *=> *'[^']*'/'affiliationAttribute' => '${_aff_escaped}'/" \
            /etc/letswifi/letswifi.conf.php
    fi

    # Grant token validity: how many days a portal login grant stays valid before the
    # user must re-authenticate to enroll additional devices.  Default: 180 (upstream).
    if [ -n "${LETSWIFI_GRANT_TOKEN_VALIDITY:-}" ]; then
        sed -i "s/'longLivedGrantTokenValidity' *=> *[0-9]*/'longLivedGrantTokenValidity' => ${LETSWIFI_GRANT_TOKEN_VALIDITY}/" \
            /etc/letswifi/letswifi.conf.php
    fi

    head -c32 /dev/random | base64 | tr -d = > /etc/letswifi/oauthsecret.txt

    rm -f /etc/letswifi/*.dist* /etc/letswifi/*.dev* /etc/letswifi/README.md
    rm -f /etc/letswifi/realms/*.conf.php /etc/letswifi/certs/*.pem
    chgrp -R apache /etc/letswifi
    chmod o-rwx /etc/letswifi/*
    echo "letswifi: letswifi config initialised"
fi

# ── SimpleSAMLphp config (first run only) ────────────────────────────────────
if [ ! -f /etc/simplesamlphp/config.php ]; then
    echo "letswifi: first run — initialising SimpleSAMLphp config"
    cp -a "$SSP"/config-templates/. /etc/simplesamlphp/ 2>/dev/null \
        || cp -a "$SSP"/config/. /etc/simplesamlphp/
    cp -n /etc/simplesamlphp/config.php.dist /etc/simplesamlphp/config.php

    SALT="${SSP_SECRET_SALT:?SSP_SECRET_SALT is required}"
    ADMIN="${SSP_ADMIN_PASSWORD:?SSP_ADMIN_PASSWORD is required}"

    sed -i \
        -e "s@'secretsalt' => 'defaultsecretsalt'@'secretsalt' => '$(sed_escape "${SALT}")'@" \
        -e "s@'auth.adminpassword' => '123'@'auth.adminpassword' => '$(sed_escape "${ADMIN}")'@" \
        -e "s@//'datadir' => '/var/data/'@'datadir' => '/var/lib/simplesamlphp/data/'@" \
        -e "s@'metadatadir' => 'metadata'@'metadatadir' => 'config/metadata'@" \
        /etc/simplesamlphp/config.php

    mkdir -p /etc/simplesamlphp/metadata

    # metarefresh: pull IdP metadata daily from your federation / IdP
    if [ -n "$SSP_IDP_METADATA_URL" ]; then
        cat > /etc/simplesamlphp/module_metarefresh.php <<EOF
<?php
\$config = ['sets' => [[
    'cron'        => ['daily'],
    'sources'     => [['src' => '${SSP_IDP_METADATA_URL}']],
    'expireAfter' => 604800,
    'outputDir'   => 'config/metadata/',
    'outputFormat'=> 'flatfile',
]]];
EOF
        echo "0 4 * * * apache php $SSP/modules/cron/bin/cron.php -t daily >/dev/null" \
            > /etc/cron.d/simplesamlphp
        echo "letswifi: IdP metadata refresh configured for ${SSP_IDP_METADATA_URL}"
    fi

    chown -R apache:apache /etc/simplesamlphp/metadata
    echo "letswifi: SimpleSAMLphp config initialised"
fi

# ── Database schema (first run only) ─────────────────────────────────────────
DB=/var/lib/letswifi/letswifi.sqlite
if [ ! -f "$DB" ]; then
    echo "letswifi: first run — creating SQLite database"
    sqlite3 "$DB" < "$APP"/sql/letswifi.sqlite.sql
    chown apache:apache "$DB"
    echo "letswifi: database created at ${DB}"
fi

# ── RADIUS trust CA discovery (runs every start) ─────────────────────────────
# Drop RADIUS server CA cert PEM(s) into /etc/letswifi/trust/ before first start.
# Certs are copied to /etc/letswifi/certs/ named by subject DN — the filename
# convention letswifi's DictionaryPemDir uses to look up certs by subject.
# Adding a cert to trust/ takes effect on the next start; updating the realm
# config's trust array requires deleting the realm file and restarting.
_trust_php=""
_trust_count=0
if [ -d /etc/letswifi/trust ]; then
    mkdir -p /etc/letswifi/certs
    for _trust_pem in /etc/letswifi/trust/*.pem; do
        [ -f "$_trust_pem" ] || continue
        # Extract subject in the format DictionaryPemDir expects:
        # KEY=VALUE, KEY=VALUE  (short names, comma-space, no spaces around =)
        _subj="$(openssl x509 -noout -subject -nameopt oneline -in "$_trust_pem" \
            | sed 's/^subject= *//' \
            | sed 's/ = /=/g')"
        if [ -z "$_subj" ]; then
            echo "letswifi: ERROR: could not read subject DN from ${_trust_pem}" >&2
            exit 1
        fi
        # Write cert-only — strips any accidental key material in the source file
        _dest="/etc/letswifi/certs/${_subj}.pem"
        openssl x509 -in "$_trust_pem" -out "$_dest"
        chmod 640 "$_dest"
        chgrp apache "$_dest"
        _escaped="$(php_escape "$_subj")"
        if [ -z "$_trust_php" ]; then
            _trust_php="'${_escaped}'"
        else
            _trust_php="${_trust_php}, '${_escaped}'"
        fi
        _trust_count=$(( _trust_count + 1 ))
        echo "letswifi: trust CA registered: ${_subj}"
    done
fi

# ── Realm + CA provisioning (first run only) ─────────────────────────────────
if [ -n "${LETSWIFI_REALM:-}" ]; then
    mkdir -p /etc/letswifi/realms /etc/letswifi/certs

    CA_CN="CN=${LETSWIFI_REALM} CA"
    CA_FILE="/etc/letswifi/certs/${CA_CN}.pem"

    # Generate the signing CA if it does not exist yet.
    # P-384 with pathlen:0 — strong enough for post-quantum transition window,
    # pathlen:0 prevents this CA from signing subordinate CAs.
    # Validity is configurable; 50-year upstream default replaced with 15 years
    # as a more defensible posture while still outlasting typical device fleets.
    if [ ! -f "$CA_FILE" ]; then
        echo "letswifi: first run — generating signing CA for realm ${LETSWIFI_REALM}"
        CA_DAYS=$(( ${LETSWIFI_REALM_CA_VALIDITY:-15} * 365 ))
        openssl req -new -x509 \
            -newkey ec \
            -pkeyopt ec_paramgen_curve:P-384 \
            -keyout /tmp/letswifi-ca.key \
            -out /tmp/letswifi-ca.crt \
            -days "$CA_DAYS" \
            -subj "/CN=${LETSWIFI_REALM} CA" \
            -nodes \
            -addext "basicConstraints=critical,CA:true,pathlen:0" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -addext "extendedKeyUsage=clientAuth" \
            -addext "subjectKeyIdentifier=hash" \
            -addext "crlDistributionPoints=URI:https://${LETSWIFI_FQDN}/crl/ca.crl"
        cat /tmp/letswifi-ca.crt /tmp/letswifi-ca.key > "$CA_FILE"
        rm -f /tmp/letswifi-ca.key /tmp/letswifi-ca.crt
        chmod 640 "$CA_FILE"
        echo "letswifi: CA generated (P-384, ${CA_DAYS} days)"
    fi

    # Write the realm config from env vars.  The CA is the permanent state;
    # the realm file is derived config and can be rewritten if vars change
    # by deleting /etc/letswifi/realms/${LETSWIFI_REALM}.conf.php and restarting.
    REALM_FILE="/etc/letswifi/realms/${LETSWIFI_REALM}.conf.php"
    if [ ! -f "$REALM_FILE" ]; then
        if [ "$_trust_count" -eq 0 ]; then
            echo "letswifi: ERROR: LETSWIFI_REALM is set but no trust CA certs were found." >&2
            echo "letswifi:        Drop your RADIUS server's CA cert PEM(s) into the" >&2
            echo "letswifi:        /etc/letswifi/trust/ directory before first start." >&2
            echo "letswifi:        Quick export from a running RADIUS server (RADSEC):" >&2
            echo "letswifi:          openssl s_client -showcerts -connect radius1.example.edu:2083 </dev/null 2>/dev/null \\" >&2
            echo "letswifi:            | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' \\" >&2
            echo "letswifi:            > /etc/letswifi/trust/radius-chain.pem" >&2
            exit 1
        fi
        echo "letswifi: first run — writing realm config for ${LETSWIFI_REALM}"
        _display="$(php_escape "${LETSWIFI_REALM_DISPLAY_NAME:-$LETSWIFI_REALM}")"
        _validity="${LETSWIFI_REALM_VALIDITY:-365}"
        _contact="$(php_escape "${LETSWIFI_REALM_CONTACT:-}")"
        _ca="$(php_escape "$CA_CN")"
        _contact_php="null"
        [ -n "${LETSWIFI_REALM_CONTACT:-}" ] && _contact_php="'${_contact}'"

        # Build the server_names PHP array from a comma-separated list.
        # Single value:  radius.manhattan.edu
        # Multiple:      radius1.manhattan.edu,radius2.manhattan.edu
        _server_names=""
        _old_ifs="$IFS"; IFS=','
        for _name in ${LETSWIFI_RADIUS_CN:-radius.$LETSWIFI_REALM}; do
            IFS="$_old_ifs"
            _name="$(printf '%s' "$_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [ -z "$_name" ] && { IFS=','; continue; }
            _escaped="$(php_escape "$_name")"
            if [ -z "$_server_names" ]; then
                _server_names="'${_escaped}'"
            else
                _server_names="${_server_names}, '${_escaped}'"
            fi
            IFS=','
        done
        IFS="$_old_ifs"

        if [ -z "$_server_names" ]; then
            echo "letswifi: ERROR: LETSWIFI_RADIUS_CN is empty — cannot write realm config." >&2
            exit 1
        fi

        cat > "$REALM_FILE" <<PHPEOF
<?php return [
    'display_name'  => ['en-GB' => '${_display}'],
    'description'   => null,
    'server_names'  => [${_server_names}],
    'validity'      => ${_validity},
    'networks'      => ['eduroam'],
    'contact'       => ${_contact_php},
    'signer'        => '${_ca}',
    'trust'         => [${_trust_php}],
];
PHPEOF
        echo "letswifi: realm config written"
    fi

    chgrp -R apache /etc/letswifi/realms /etc/letswifi/certs
    chmod o-rwx /etc/letswifi/realms/* /etc/letswifi/certs/*

    # Generate an initial CRL so /crl/ca.crl is available immediately after start.
    # The cron job (every 6 hours) keeps it fresh; this covers the restart gap.
    mkdir -p /var/www/letswifi-crl
    chown apache:apache /var/www/letswifi-crl
    su -s /bin/sh apache -c "/usr/local/bin/letswifi-gen-crl '${LETSWIFI_REALM}'" \
        || echo "letswifi: WARNING: initial CRL generation failed — the systemd timer will retry in 6 hours" >&2
fi

# ── Branding config (first run only) ─────────────────────────────────────────
if [ ! -f /etc/letswifi/branding.conf.php ] && [ -n "${LETSWIFI_PRODUCT_NAME:-}" ]; then
    echo "letswifi: first run — writing branding config"

    SHORTNAME="${LETSWIFI_PRODUCT_SHORTNAME:-$(printf '%s' "$LETSWIFI_PRODUCT_NAME" \
        | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')}"
    NETWORK="${LETSWIFI_NETWORK_NAME:-eduroam}"

    # Detect CSS and favicon from the branding volume directory
    _css='' _favicon=''
    if [ -d /etc/letswifi/branding ]; then
        for _f in /etc/letswifi/branding/*.css;              do [ -f "$_f" ] && _css=$(basename "$_f")     && break; done
        for _f in /etc/letswifi/branding/*.ico;              do [ -f "$_f" ] && _favicon=$(basename "$_f") && break; done
        if [ -z "$_favicon" ]; then
            for _f in /etc/letswifi/branding/*.svg /etc/letswifi/branding/*.png; do
                [ -f "$_f" ] && _favicon=$(basename "$_f") && break
            done
        fi
    fi

    {
        cat <<PHPEOF
<?php
return [
    'product_name'      => '$(php_escape "$LETSWIFI_PRODUCT_NAME")',
    'product_shortname' => '$(php_escape "$SHORTNAME")',
    'network_name'      => '$(php_escape "$NETWORK")',
PHPEOF
        [ -n "$_css" ]     && printf "    'css_file'     => '%s',\n" "$(php_escape "$_css")"
        [ -n "$_favicon" ] && printf "    'favicon_file' => '%s',\n" "$(php_escape "$_favicon")"
        cat <<'PHPEOF'

    'platforms' => [
        'android'    => ['name' => 'Android',  'match' => 'Android [1-9][0-9]+;',                       'apps' => ['play-store', 'f-droid']],
        'chromebook' => ['name' => 'ChromeOS', 'match' => 'CrOS',                                       'apps' => ['play-store'],           'profiles' => ['google-onc']],
        'ios'        => ['name' => 'iOS',       'match' => '(iPad|iPhone|iPod);.*OS [1-9][0-9]+_[0-9]', 'apps' => ['app-store'],            'profiles' => ['apple-mobileconfig']],
        'linux'      => ['name' => 'Linux',     'match' => '(Linux;? *[^A]|X11;? *Linux)',               'apps' => ['flathub', 'github-linux']],
        'macos'      => ['name' => 'macOS',     'match' => 'Mac OS X [1-9][0-9]+[._][0-9]',                                                  'profiles' => ['apple-mobileconfig']],
        'windows'    => ['name' => 'Windows',   'match' => 'Windows NT [0-9]',                           'apps' => ['winnt-amd64', 'winnt-arm64']],
    ],

    'apps' => [
        'app-store'    => ['name' => 'App Store',      'href' => 'https://apps.apple.com/app/geteduroam/id1504076137',                   'type' => 'store'],
        'f-droid'      => ['name' => 'F-Droid',        'href' => 'https://f-droid.org/en/packages/app.eduroam.geteduroam/',              'type' => 'store'],
        'flathub'      => ['name' => 'Flathub',        'href' => 'https://flathub.org/apps/app.eduroam.geteduroam/',                     'type' => 'store'],
        'github-linux' => ['name' => 'GitHub Release', 'href' => 'https://github.com/geteduroam/linux-app/releases/',                   'type' => 'link'],
        'play-store'   => ['name' => 'Play Store',     'href' => 'https://play.google.com/store/apps/details?id=app.eduroam.geteduroam', 'type' => 'store'],
        'winnt-amd64'  => ['name' => 'x64 EXE',        'href' => 'https://dl.eduroam.app/windows/amd64/geteduroam.exe',                  'type' => 'download'],
        'winnt-arm64'  => ['name' => 'arm64 EXE',      'href' => 'https://dl.eduroam.app/windows/arm64/geteduroam.exe',                  'type' => 'download'],
    ],

    'profiles' => [
        'google-onc'         => ['name' => 'ONC Profile'],
        'apple-mobileconfig' => ['name' => 'Apple Configuration Profile'],
    ],
];
PHPEOF
    } > /etc/letswifi/branding.conf.php

    # Enable branding in letswifi.conf.php (the line is commented out by default)
    sed -i "s@// 'branding#inc' => 'branding-eduroam.conf.php',@'branding#inc' => 'branding.conf.php',@" \
        /etc/letswifi/letswifi.conf.php

    # Persist shortname for asset symlinking on subsequent starts
    printf '%s' "$SHORTNAME" > /etc/letswifi/branding.shortname

    echo "letswifi: branding config written (product: ${LETSWIFI_PRODUCT_NAME}, shortname: ${SHORTNAME})"
fi

# ── Branding assets (re-evaluated every start — update files and restart) ─────
if [ -f /etc/letswifi/branding.shortname ] && [ -d /etc/letswifi/branding ]; then
    _shortname=$(cat /etc/letswifi/branding.shortname)
    ln -sfn /etc/letswifi/branding "$APP/htdocs/assets/branding/${_shortname}"
    echo "letswifi: branding assets linked → htdocs/assets/branding/${_shortname}/"
fi

# ── TLS / mTLS (re-evaluated every start — swap certs without rebuilding) ────
#
# HTTPS is enabled automatically when cert + key are present.
# mTLS is enabled automatically when a CA cert is also present.
#
# Cert paths (mount these via a volume or Podman secret/bind-mount):
#   Server cert:  /etc/pki/tls/certs/letswifi.crt
#   Server key:   /etc/pki/tls/private/letswifi.key
#   CA cert:      /etc/pki/tls/certs/ca.crt   (optional — enables mTLS)
#
# Change PublishPort in letswifi.container to 8443:443 when using TLS.

if [ -f "$CERT" ] || [ -f "$KEY" ]; then
    # Partial configuration is always an error
    if [ ! -f "$CERT" ]; then
        echo "letswifi: ERROR: TLS key found at ${KEY} but certificate is missing." >&2
        echo "letswifi:        Place the server certificate at: ${CERT}" >&2
        exit 1
    fi
    if [ ! -f "$KEY" ]; then
        echo "letswifi: ERROR: TLS certificate found at ${CERT} but private key is missing." >&2
        echo "letswifi:        Place the private key at: ${KEY}" >&2
        exit 1
    fi

    if [ -f "$CA" ]; then
        echo "letswifi: CA cert found — HTTPS with mTLS enabled on port 443"
        echo "letswifi:   server cert: ${CERT}"
        echo "letswifi:   CA cert:     ${CA} (client certificates required)"
        MTLS_DIRECTIVES="    # mTLS — clients must present a certificate signed by the CA above.
    # SSLOptions +ExportCertData makes the client cert available to PHP via
    # \$_SERVER['SSL_CLIENT_CERT'] for letswifi's certificate renewal flow.
    SSLVerifyClient      require
    SSLCACertificateFile ${CA}
    SSLOptions           +ExportCertData"
    else
        echo "letswifi: TLS cert found — HTTPS enabled on port 443 (no mTLS)"
        echo "letswifi:   server cert: ${CERT}"
        echo "letswifi:   to enable mTLS, add a CA cert at: ${CA}"
        MTLS_DIRECTIVES=""
    fi

    # Regenerate the SSL vhost on every start so cert/mTLS changes take effect.
    cat > "$SSL_CONF" <<EOF
# Generated by entrypoint.sh on every container start. Do not edit here.
# To reconfigure TLS, change the cert files and restart the container.
<VirtualHost *:443>
    ServerName      ${LETSWIFI_FQDN}
    DocumentRoot    /usr/local/share/letswifi-portal/htdocs
    Alias /simplesaml /usr/local/share/simplesamlphp/public
    Alias /crl        /var/www/letswifi-crl

    SetEnv SIMPLESAMLPHP_CONFIG_DIR /etc/simplesamlphp
    SetEnv LETSWIFI_CONFIG_DIR      /etc/letswifi

    SSLEngine             on
    SSLCertificateFile    ${CERT}
    SSLCertificateKeyFile ${KEY}

    # Defer to the RHEL/UBI system crypto policy (update-crypto-policies).
    # DEFAULT on UBI 10: TLS 1.2+, AEAD ciphers, forward secrecy required.
    # To enforce TLS 1.3 only, run inside the container:
    #   update-crypto-policies --set FUTURE
    # or mount a custom policy into /etc/crypto-policies/back-ends/.
    # FIPS mode is inherited automatically if the host kernel is FIPS-enabled.
    SSLProtocol           all -SSLv3
    SSLCipherSuite        PROFILE=SYSTEM
    SSLHonorCipherOrder   off
    # Session tickets are not controlled by the system policy; disable them
    # explicitly to ensure forward secrecy is not weakened by ticket reuse.
    SSLSessionTickets     off

${MTLS_DIRECTIVES}

    # 2-year HSTS — only set this once you're certain HTTPS is permanent.
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"
    Header always set Content-Security-Policy "default-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none';"
    Header always set Referrer-Policy         "no-referrer"
    Header always set X-Frame-Options         "DENY"
    Header always set X-Content-Type-Options  "nosniff"

    <FilesMatch \.php\$>
        SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost"
    </FilesMatch>

    <Directory /usr/local/share/letswifi-portal/htdocs>
        Require all granted
    </Directory>
    <Directory /usr/local/share/simplesamlphp/public>
        Require all granted
    </Directory>
    <Directory /var/www/letswifi-crl>
        Require all granted
        Options -Indexes
    </Directory>
</VirtualHost>
EOF

else
    # No certs — remove any stale SSL conf from a previous run.
    rm -f "$SSL_CONF"
    echo "letswifi: no TLS cert found — running HTTP only on port 80"
    echo "letswifi: to enable HTTPS, provide:"
    echo "letswifi:   server cert:  ${CERT}"
    echo "letswifi:   server key:   ${KEY}"
    echo "letswifi:   CA cert:      ${CA}  (optional, enables mTLS)"
    echo "letswifi: also change PublishPort to 8443:443 in letswifi.container"
fi

exec /sbin/init