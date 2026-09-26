#!/bin/bash
# =============================================================================
#  LAMP Stack Auto-Installer for Ubuntu 26.04
#  Installs: Apache2 (MPM Event) + PHP 8.4-FPM (CodeIgniter 4 ready) +
#            2x Redis (app cache :6379 + PHP sessions :6380) + Certbot +
#            Webmin + Midnight Commander + ncdu + ImageMagick
#  Config is calculated automatically from detected CPU and RAM
#  Author: Ruvenss G Wilches: <ruvenss@gmail.com>
#  GitHub: https://github.com/ruvenss/super_lamp
# =============================================================================

set -e

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${BLUE}  $1${NC}"; \
            echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"; }

# ─── Root check ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root. Use: sudo bash $0"
fi

# ─── Ubuntu 26.04 check ──────────────────────────────────────────────────────
if ! grep -q "26.04" /etc/os-release 2>/dev/null; then
  warn "This script was designed for Ubuntu 26.04. Proceeding anyway..."
fi

# ─── Versions / ports ────────────────────────────────────────────────────────
# PHP 8.4 is the newest version officially supported by CodeIgniter 4.6
PHP_V="8.4"
REDIS_CACHE_PORT=6379     # app / code cache — safe to flush on every deploy
REDIS_SESSION_PORT=6380   # PHP sessions — persistent, never flushed on deploy

# =============================================================================
#  STEP 1 — Detect hardware and calculate config values
# =============================================================================
section "Detecting hardware"

VCPU=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$((RAM_KB / 1024))
RAM_GB=$((RAM_MB / 1024))
DISK_GB=$(df -BG / | awk 'NR==2 {print $2}' | tr -d 'G')

info "Detected: ${VCPU} vCPU | ${RAM_GB} GB RAM (${RAM_MB} MB) | ${DISK_GB} GB disk"

# ── PHP-FPM ──────────────────────────────────────────────────────────────────
# Reserve: OS=512MB, Apache=512MB, OPcache block=variable, Redis=variable
# Remaining ÷ 40 MB per worker = max_children

if   [[ $RAM_GB -le 2 ]];  then
  PHP_MAX_CHILDREN=8
  PHP_MEMORY_LIMIT="64M"
  OPCACHE_MEM=64
  OPCACHE_JIT_BUF="32M"
  OPCACHE_MAX_FILES=10000
  REDIS_MAX="128mb"
  REDIS_SESSION_MAX="64mb"
  APACHE_MAX_WORKERS=25
  HUGEPAGES=32
  REDIS_IO_THREADS=1
elif [[ $RAM_GB -le 4 ]];  then
  PHP_MAX_CHILDREN=25
  PHP_MEMORY_LIMIT="128M"
  OPCACHE_MEM=128
  OPCACHE_JIT_BUF="64M"
  OPCACHE_MAX_FILES=20000
  REDIS_MAX="256mb"
  REDIS_SESSION_MAX="128mb"
  APACHE_MAX_WORKERS=50
  HUGEPAGES=64
  REDIS_IO_THREADS=1
elif [[ $RAM_GB -le 8 ]];  then
  PHP_MAX_CHILDREN=50
  PHP_MEMORY_LIMIT="256M"
  OPCACHE_MEM=256
  OPCACHE_JIT_BUF="128M"
  OPCACHE_MAX_FILES=30000
  REDIS_MAX="512mb"
  REDIS_SESSION_MAX="256mb"
  APACHE_MAX_WORKERS=100
  HUGEPAGES=128
  REDIS_IO_THREADS=2
elif [[ $RAM_GB -le 16 ]]; then
  PHP_MAX_CHILDREN=100
  PHP_MEMORY_LIMIT="256M"
  OPCACHE_MEM=384
  OPCACHE_JIT_BUF="128M"
  OPCACHE_MAX_FILES=60000
  REDIS_MAX="1gb"
  REDIS_SESSION_MAX="512mb"
  APACHE_MAX_WORKERS=200
  HUGEPAGES=256
  REDIS_IO_THREADS=4
elif [[ $RAM_GB -le 24 ]]; then
  PHP_MAX_CHILDREN=150
  PHP_MEMORY_LIMIT="256M"
  OPCACHE_MEM=512
  OPCACHE_JIT_BUF="256M"
  OPCACHE_MAX_FILES=100000
  REDIS_MAX="2gb"
  REDIS_SESSION_MAX="768mb"
  APACHE_MAX_WORKERS=300
  HUGEPAGES=384
  REDIS_IO_THREADS=6
else
  PHP_MAX_CHILDREN=200
  PHP_MEMORY_LIMIT="256M"
  OPCACHE_MEM=512
  OPCACHE_JIT_BUF="256M"
  OPCACHE_MAX_FILES=100000
  REDIS_MAX="4gb"
  REDIS_SESSION_MAX="1gb"
  APACHE_MAX_WORKERS=400
  HUGEPAGES=512
  REDIS_IO_THREADS=8
fi

# ── FPM dynamic pool ─────────────────────────────────────────────────────────
PHP_START_SERVERS=$(( VCPU * 2 ))
PHP_MIN_SPARE=$(( VCPU ))
PHP_MAX_SPARE=$(( VCPU * 4 ))
[[ $PHP_START_SERVERS -lt 2 ]] && PHP_START_SERVERS=2
[[ $PHP_MIN_SPARE    -lt 2 ]] && PHP_MIN_SPARE=2
[[ $PHP_MAX_SPARE    -lt 4 ]] && PHP_MAX_SPARE=4

# ── Apache MPM Event ─────────────────────────────────────────────────────────
APACHE_START_SERVERS=$VCPU
APACHE_THREADS_PER_CHILD=25
APACHE_MIN_SPARE_THREADS=$(( VCPU * 5 ))
APACHE_MAX_SPARE_THREADS=$(( VCPU * 15 ))
[[ $APACHE_MIN_SPARE_THREADS -lt 10 ]] && APACHE_MIN_SPARE_THREADS=10
[[ $APACHE_MAX_SPARE_THREADS -lt 30 ]] && APACHE_MAX_SPARE_THREADS=30

# ── tmpfs for sessions ───────────────────────────────────────────────────────
if   [[ $RAM_GB -le 4 ]];  then SESSION_TMPFS="128M"
elif [[ $RAM_GB -le 8 ]];  then SESSION_TMPFS="256M"
elif [[ $RAM_GB -le 16 ]]; then SESSION_TMPFS="512M"
else                             SESSION_TMPFS="1G"
fi

# ── Kernel TCP buffers ───────────────────────────────────────────────────────
if   [[ $RAM_GB -le 4 ]];  then TCP_BUF=16777216
elif [[ $RAM_GB -le 8 ]];  then TCP_BUF=16777216
elif [[ $RAM_GB -le 16 ]]; then TCP_BUF=33554432
else                             TCP_BUF=67108864
fi

echo ""
info "Calculated configuration:"
echo "  PHP-FPM  max_children   = ${PHP_MAX_CHILDREN}"
echo "  PHP-FPM  start_servers  = ${PHP_START_SERVERS}"
echo "  PHP      memory_limit   = ${PHP_MEMORY_LIMIT}"
echo "  OPcache  memory         = ${OPCACHE_MEM} MB"
echo "  OPcache  JIT buffer     = ${OPCACHE_JIT_BUF}"
echo "  Redis    cache maxmem   = ${REDIS_MAX} (port ${REDIS_CACHE_PORT})"
echo "  Redis    session maxmem = ${REDIS_SESSION_MAX} (port ${REDIS_SESSION_PORT})"
echo "  Apache   MaxRequestWorkers = ${APACHE_MAX_WORKERS}"
echo "  Apache   StartServers   = ${APACHE_START_SERVERS}"
echo "  Hugepages               = ${HUGEPAGES}"

# =============================================================================
#  STEP 2 — Ask for domain
# =============================================================================
section "Domain configuration"

echo ""
read -rp "$(echo -e "${BOLD}Enter your domain name (e.g. example.com or api.example.com): ${NC}")" DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)

if [[ -z "$DOMAIN" ]]; then
  error "Domain name cannot be empty."
fi

# Project root under /home/<domain>; CodeIgniter 4 serves from <root>/public
DOC_ROOT="/home/${DOMAIN}"
WEB_ROOT="${DOC_ROOT}/public"

info "Domain    : ${DOMAIN}"
info "Doc root  : ${DOC_ROOT}"
info "Web root  : ${WEB_ROOT}"

# =============================================================================
#  STEP 3 — System update
# =============================================================================
section "System update"

apt-get update -qq && apt-get upgrade -y -qq
success "System updated"

# =============================================================================
#  STEP 4 — Install core utilities
# =============================================================================
section "Installing utilities (mc, ncdu, imagemagick, curl, git...)"

apt-get install -y -qq \
  curl wget git unzip zip \
  mc ncdu htop iotop \
  imagemagick \
  software-properties-common \
  ca-certificates \
  gnupg lsb-release \
  ufw fail2ban

success "Utilities installed"

# =============================================================================
#  STEP 5 — Apache2
# =============================================================================
section "Installing Apache2"

apt-get install -y -qq apache2

# Disable mod_php and prefork if present
for mod in /etc/apache2/mods-enabled/php*.load; do
  [[ -e "$mod" ]] && a2dismod "$(basename "$mod" .load)" || true
done
a2dismod mpm_prefork 2>/dev/null || true

# Enable required modules
a2enmod mpm_event
a2enmod proxy_fcgi setenvif
a2enmod rewrite
a2enmod deflate
a2enmod headers
a2enmod expires
a2enmod ssl

success "Apache2 installed and modules enabled"

# ── MPM Event config ─────────────────────────────────────────────────────────
info "Writing MPM Event config..."

cat > /etc/apache2/mods-available/mpm_event.conf <<EOF
<IfModule mpm_event_module>
    StartServers             ${APACHE_START_SERVERS}
    MinSpareThreads          ${APACHE_MIN_SPARE_THREADS}
    MaxSpareThreads          ${APACHE_MAX_SPARE_THREADS}
    ThreadLimit              64
    ThreadsPerChild          ${APACHE_THREADS_PER_CHILD}
    MaxRequestWorkers        ${APACHE_MAX_WORKERS}
    MaxConnectionsPerChild   2000
</IfModule>
EOF

success "MPM Event configured"

# =============================================================================
#  STEP 6 — PHP 8.4-FPM (CodeIgniter 4 compatible)
# =============================================================================
section "Installing PHP ${PHP_V}-FPM"
curl -fsSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
. /etc/os-release
ARCH="$(dpkg --print-architecture)"

case "$VERSION_CODENAME:$ARCH" in
  resolute:amd64|resolute:arm64|noble:amd64|noble:arm64|noble:armhf|jammy:amd64|jammy:arm64|jammy:armhf)
    printf '%s\n' \
      'Types: deb' \
      'URIs: https://packages.sury.org/php/' \
      "Suites: $VERSION_CODENAME" \
      'Components: main' \
      "Architectures: $ARCH" \
      'Signed-By: /usr/share/keyrings/deb.sury.org-php.gpg' | tee /etc/apt/sources.list.d/php.sources > /dev/null
    ;;
  *)
    printf 'This PHP 8.4 workflow covers Ubuntu 26.04 on amd64/arm64 and Ubuntu 24.04/22.04 on amd64/arm64/armhf; this host reports %s/%s.\n' "$VERSION_CODENAME" "$ARCH" >&2
    false
    ;;
esac
apt-get update -qq
# intl + mbstring + mysql (mysqlnd) + curl are required by CodeIgniter 4;
# redis powers CI's RedisHandler (cache + sessions)
apt-get install -y -qq \
  php${PHP_V}-fpm \
  php${PHP_V}-cli \
  php${PHP_V}-common \
  php${PHP_V}-mysql \
  php${PHP_V}-sqlite3 \
  php${PHP_V}-redis \
  php${PHP_V}-mbstring \
  php${PHP_V}-xml \
  php${PHP_V}-curl \
  php${PHP_V}-zip \
  php${PHP_V}-intl \
  php${PHP_V}-gd \
  php${PHP_V}-imagick \
  php${PHP_V}-bcmath \
  php${PHP_V}-soap

# Make sure the CLI (spark, composer) uses the same PHP as FPM
update-alternatives --set php "/usr/bin/php${PHP_V}" 2>/dev/null || true

# Composer — needed to install / update CodeIgniter 4 projects
if ! command -v composer &>/dev/null; then
  curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

a2enconf "php${PHP_V}-fpm"
success "PHP ${PHP_V}-FPM installed"

# ── FPM pool config ───────────────────────────────────────────────────────────
info "Writing PHP-FPM pool config..."

cat > /etc/php/${PHP_V}/fpm/pool.d/www.conf <<EOF
[www]
user = www-data
group = www-data

listen = /run/php/php-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
listen.backlog = 65535

pm = dynamic
pm.max_children = ${PHP_MAX_CHILDREN}
pm.start_servers = ${PHP_START_SERVERS}
pm.min_spare_servers = ${PHP_MIN_SPARE}
pm.max_spare_servers = ${PHP_MAX_SPARE}
pm.max_requests = 1000

request_slowlog_timeout = 3s
slowlog = /var/log/php${PHP_V}-fpm-slow.log

php_admin_value[memory_limit] = ${PHP_MEMORY_LIMIT}
php_admin_value[max_execution_time] = 30
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[error_log] = /var/log/php${PHP_V}-fpm-error.log
php_flag[display_errors] = off
EOF

success "PHP-FPM pool configured"

# ── OPcache + JIT ────────────────────────────────────────────────────────────
info "Writing OPcache + JIT config..."

cat > /etc/php/${PHP_V}/fpm/conf.d/99-perf.ini <<EOF
; OPcache
opcache.enable = 1
opcache.memory_consumption = ${OPCACHE_MEM}
opcache.interned_strings_buffer = 32
opcache.max_accelerated_files = ${OPCACHE_MAX_FILES}
opcache.revalidate_freq = 0
opcache.validate_timestamps = 0
opcache.save_comments = 1
opcache.huge_code_pages = 1

; JIT
opcache.jit = tracing
opcache.jit_buffer_size = ${OPCACHE_JIT_BUF}

; Realpath cache
realpath_cache_size = 8192K
realpath_cache_ttl = 600

; General
memory_limit = ${PHP_MEMORY_LIMIT}
max_execution_time = 30

; Native PHP sessions -> dedicated sessions Redis (survives cache flushes)
; CodeIgniter 4 uses its own Session config — see the notes at the end.
session.save_handler = redis
session.save_path = "tcp://127.0.0.1:${REDIS_SESSION_PORT}"
redis.session.locking_enabled = 1
EOF

success "OPcache + JIT configured"

# =============================================================================
#  STEP 7 — Redis (two instances)
#    :6379  redis-server    — app/code cache, LRU, no persistence, flush freely
#    :6380  redis-sessions  — PHP sessions, persisted to disk, FLUSH disabled
# =============================================================================
section "Installing Redis (cache + sessions)"

apt-get install -y -qq redis-server redis-tools
REDIS_BIN=$(command -v redis-server)

# ── Instance 1: cache ────────────────────────────────────────────────────────
cat > /etc/redis/redis.conf <<EOF
bind 127.0.0.1
port ${REDIS_CACHE_PORT}
dir /var/lib/redis
logfile /var/log/redis/redis-server.log
maxmemory ${REDIS_MAX}
maxmemory-policy allkeys-lru
save ""
appendonly no
tcp-backlog 511
tcp-keepalive 300
io-threads ${REDIS_IO_THREADS}
io-threads-do-reads yes
EOF

systemctl enable redis-server
success "Redis cache configured on :${REDIS_CACHE_PORT} (maxmemory: ${REDIS_MAX})"

# ── Instance 2: sessions ─────────────────────────────────────────────────────
mkdir -p /var/lib/redis-sessions
chown redis:redis /var/lib/redis-sessions
chmod 750 /var/lib/redis-sessions

cat > /etc/redis/redis-sessions.conf <<EOF
bind 127.0.0.1
port ${REDIS_SESSION_PORT}
dir /var/lib/redis-sessions
logfile /var/log/redis/redis-sessions.log
maxmemory ${REDIS_SESSION_MAX}
# Sessions always carry a TTL: under pressure drop the ones closest to expiry
maxmemory-policy volatile-ttl

# Persist so users stay logged in across Redis restarts / reboots
appendonly yes
appendfilename "sessions.aof"
appendfsync everysec
dbfilename sessions.rdb
save 3600 1 300 100 60 10000

# Guard against an accidental flush wiping every logged-in user
rename-command FLUSHALL ""
rename-command FLUSHDB ""

tcp-backlog 511
tcp-keepalive 300
EOF
chown redis:redis /etc/redis/redis-sessions.conf
chmod 640 /etc/redis/redis-sessions.conf

cat > /etc/systemd/system/redis-sessions.service <<EOF
[Unit]
Description=Redis — PHP session store (port ${REDIS_SESSION_PORT})
After=network.target

[Service]
Type=notify
User=redis
Group=redis
ExecStart=${REDIS_BIN} /etc/redis/redis-sessions.conf --supervised systemd --daemonize no
Restart=always
RestartSec=2
LimitNOFILE=65535
RuntimeDirectory=redis-sessions
RuntimeDirectoryMode=2755

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable redis-sessions
success "Redis sessions configured on :${REDIS_SESSION_PORT} (maxmemory: ${REDIS_SESSION_MAX}, persistent)"

# ── Deploy helper: refresh code cache without touching sessions ──────────────
cat > /usr/local/bin/refresh-code-cache <<EOF
#!/bin/bash
# Flush the app/code cache Redis and OPcache. Sessions (:${REDIS_SESSION_PORT}) are untouched.
set -e
redis-cli -p ${REDIS_CACHE_PORT} FLUSHALL
systemctl reload php${PHP_V}-fpm
echo "Code cache + OPcache flushed — user sessions kept."
EOF
chmod 755 /usr/local/bin/refresh-code-cache

# =============================================================================
#  STEP 8 — Document root and VirtualHost
# =============================================================================
section "Creating VirtualHost for ${DOMAIN}"

# Only create doc root and set permissions if it doesn't exist
if [[ ! -d "${DOC_ROOT}" ]]; then
  mkdir -p "${WEB_ROOT}"
  chown -R www-data:www-data "${DOC_ROOT}"
  chmod 750 "${DOC_ROOT}"
elif [[ ! -d "${WEB_ROOT}" ]]; then
  mkdir -p "${WEB_ROOT}"
  chown www-data:www-data "${WEB_ROOT}"
fi


# Write VirtualHost — port 80, no SSL (certbot later)
cat > "/etc/apache2/sites-available/${DOMAIN}.conf" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${WEB_ROOT}

    <Directory ${WEB_ROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch "\.php\$">
        SetHandler "proxy:unix:/run/php/php-fpm.sock|fcgi://localhost"
    </FilesMatch>

    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/css application/javascript application/json text/xml application/xml
    </IfModule>

    <IfModule mod_expires.c>
        ExpiresActive On
        ExpiresByType image/webp   "access plus 1 year"
        ExpiresByType image/jpeg   "access plus 1 year"
        ExpiresByType image/png    "access plus 1 year"
        ExpiresByType text/css     "access plus 1 month"
        ExpiresByType application/javascript "access plus 1 month"
    </IfModule>

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>
EOF

# Enable site, disable default
a2ensite "${DOMAIN}.conf"
a2dissite 000-default.conf 2>/dev/null || true

success "VirtualHost created at /etc/apache2/sites-available/${DOMAIN}.conf"

# =============================================================================
#  STEP 9 — Certbot and snapd
# =============================================================================
section "Installing Certbot"
apt install -y -qq snapd
snap install --classic certbot
if [[ ! -e /usr/local/bin/certbot ]]; then
  ln -s /snap/bin/certbot /usr/local/bin/certbot
fi
success "Certbot installed"
info "To enable SSL later, run:"
echo -e "  ${BOLD}sudo certbot --apache -d ${DOMAIN}${NC}"

# =============================================================================
#  STEP 10 — Webmin
# =============================================================================
section "Installing Webmin"
if dpkg -l | grep -qw webmin; then
  info "Webmin is already installed, skipping"
else
  curl -o webmin-setup-repo.sh https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh
  sudo sh webmin-setup-repo.sh

  apt-get update -qq
  apt-get install -y -qq webmin usermin

  success "Webmin installed — accessible at https://$(hostname -I | awk '{print $1}'):10000"
fi

# =============================================================================
#  STEP 11 — Kernel tuning
# =============================================================================
section "Applying kernel tuning"

cat > /etc/sysctl.d/99-webserver.conf <<EOF
net.core.rmem_max = ${TCP_BUF}
net.core.wmem_max = ${TCP_BUF}
net.ipv4.tcp_rmem = 4096 87380 ${TCP_BUF}
net.ipv4.tcp_wmem = 4096 65536 ${TCP_BUF}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
fs.file-max = 1000000
vm.nr_hugepages = ${HUGEPAGES}
# Lets the sessions Redis fork for background saves without failing
vm.overcommit_memory = 1
EOF

sysctl -p /etc/sysctl.d/99-webserver.conf > /dev/null
success "Kernel parameters applied"

# ── File descriptor limits ───────────────────────────────────────────────────
cat >> /etc/security/limits.conf <<EOF
www-data soft nofile 65535
www-data hard nofile 65535
EOF

# =============================================================================
#  STEP 12 — PHP sessions in tmpfs
# =============================================================================
section "Moving PHP sessions to tmpfs"

# Only add if not already present
if ! grep -q "php/sessions" /etc/fstab; then
  echo "tmpfs /var/lib/php/sessions tmpfs defaults,size=${SESSION_TMPFS},mode=1733 0 0" \
    >> /etc/fstab
  mount -a
  success "PHP sessions mounted in RAM (${SESSION_TMPFS})"
else
  info "tmpfs for sessions already in fstab, skipping"
fi

# =============================================================================
#  STEP 13 — Log rotation for slow log
# =============================================================================
cat > /etc/logrotate.d/php${PHP_V}-fpm-slow <<EOF
/var/log/php${PHP_V}-fpm-slow.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    postrotate
        /usr/lib/php/php${PHP_V}-fpm-reopenlogs
    endscript
}
EOF

# =============================================================================
#  STEP 14 — Start and enable all services
# =============================================================================
section "Starting services"

systemctl enable "php${PHP_V}-fpm" apache2 redis-server redis-sessions
systemctl restart redis-server
systemctl restart redis-sessions
systemctl restart "php${PHP_V}-fpm"
systemctl restart apache2

# Verify
apache2ctl configtest && success "Apache config syntax OK" || error "Apache config has errors — check above"

# =============================================================================
#  STEP 15 — Health check
# =============================================================================
section "Health check"

echo ""
PHP_VERSION_STR=$(php -r "echo PHP_VERSION;")
APACHE_VER=$(apache2 -v | grep version | awk '{print $3}')
REDIS_VER=$(redis-server --version | awk '{print $3}')

echo -e "  ${GREEN}PHP${NC}     : ${PHP_VERSION_STR}"
echo -e "  ${GREEN}Apache${NC}  : ${APACHE_VER}"
echo -e "  ${GREEN}Redis${NC}   : ${REDIS_VER}"
echo -e "  ${GREEN}Cache${NC}   : :${REDIS_CACHE_PORT} $(redis-cli -p ${REDIS_CACHE_PORT} ping 2>/dev/null || echo 'DOWN!')"
echo -e "  ${GREEN}Sessions${NC}: :${REDIS_SESSION_PORT} $(redis-cli -p ${REDIS_SESSION_PORT} ping 2>/dev/null || echo 'DOWN!')"
echo -e "  ${GREEN}OPcache${NC} : $(php -r "echo opcache_get_status() ? 'enabled' : 'disabled';" 2>/dev/null || echo 'check manually')"
echo ""
echo -e "  ${GREEN}MPM${NC}     : $(apache2ctl -V 2>/dev/null | grep MPM | awk '{print $3}')"
echo -e "  ${GREEN}Socket${NC}  : $(ls /run/php/php-fpm.sock 2>/dev/null && echo 'exists' || echo 'missing!')"
echo ""

# Memory summary
echo -e "  ${BOLD}RAM budget:${NC}"
echo -e "    FPM workers  : ${PHP_MAX_CHILDREN} × 40 MB = $(( PHP_MAX_CHILDREN * 40 )) MB"
echo -e "    OPcache      : ${OPCACHE_MEM} MB"
echo -e "    Redis cache  : ${REDIS_MAX}"
echo -e "    Redis session: ${REDIS_SESSION_MAX}"
echo -e "    Sessions     : ${SESSION_TMPFS} (tmpfs)"
free -h | grep Mem | awk '{printf "    Total RAM    : %s  |  Used: %s  |  Free: %s\n", $2, $3, $4}'

# =============================================================================
#  STEP 16 — Performance benchmark
# =============================================================================
section "Performance benchmark"
 
# Install apache2-utils if not present (provides ab)
if ! command -v ab &>/dev/null; then
  info "Installing apache2-utils for Apache Bench..."
  apt-get install -y -qq apache2-utils
fi

ab -n 1000 -c 50 http://127.0.0.1/


# =============================================================================
#  DONE
# =============================================================================
section "Installation complete"

SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "  ${BOLD}Your server is ready.${NC}"
echo ""
echo -e "  Site URL     : ${CYAN}http://${DOMAIN}${NC}"
echo -e "  Doc root     : ${CYAN}${DOC_ROOT}${NC}  (web root: ${WEB_ROOT})"
echo -e "  Webmin       : ${CYAN}https://${SERVER_IP}:10000${NC}"
echo ""
echo -e "  ${BOLD}To enable SSL (HTTPS) when DNS is pointing to this server:${NC}"
echo -e "  ${YELLOW}sudo certbot --apache -d ${DOMAIN} -d www.${DOMAIN}${NC}"
echo ""
echo -e "  ${BOLD}To deploy new code (flushes cache Redis + OPcache, keeps sessions):${NC}"
echo -e "  ${YELLOW}sudo refresh-code-cache${NC}"
echo ""
echo -e "  ${BOLD}CodeIgniter 4 — add to your project's .env:${NC}"
echo -e "  ${YELLOW}cache.handler = redis${NC}"
echo -e "  ${YELLOW}cache.redis.host = 127.0.0.1${NC}"
echo -e "  ${YELLOW}cache.redis.port = ${REDIS_CACHE_PORT}${NC}"
echo -e "  ${YELLOW}session.driver = 'CodeIgniter\\Session\\Handlers\\RedisHandler'${NC}"
echo -e "  ${YELLOW}session.savePath = 'tcp://127.0.0.1:${REDIS_SESSION_PORT}'${NC}"
echo ""
echo -e "  ${BOLD}Monitor workers:${NC}"
echo -e "  ${YELLOW}ps --no-headers -o rss -C php-fpm${PHP_V} | awk '{sum+=\$1;n++} END {printf \"workers: %d  avg: %.1fMB  total: %.0fMB\\n\",n,sum/n/1024,sum/1024}'${NC}"
echo ""
