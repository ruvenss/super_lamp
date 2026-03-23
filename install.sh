#!/bin/bash
# =============================================================================
#  LAMP Stack Auto-Installer for Ubuntu 24.04
#  Installs: Apache2 (MPM Event) + PHP 8.3-FPM + Redis + Certbot +
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

# ─── Ubuntu 24.04 check ──────────────────────────────────────────────────────
if ! grep -q "24.04" /etc/os-release 2>/dev/null; then
  warn "This script was designed for Ubuntu 24.04. Proceeding anyway..."
fi

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
echo "  Redis    maxmemory      = ${REDIS_MAX}"
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

# Document root under /home/<domain>
DOC_ROOT="/home/${DOMAIN}"

info "Domain    : ${DOMAIN}"
info "Doc root  : ${DOC_ROOT}"

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
  apt-transport-https \
  gnupg2 lsb-release \
  ufw fail2ban

success "Utilities installed"

# =============================================================================
#  STEP 5 — Apache2
# =============================================================================
section "Installing Apache2"

apt-get install -y -qq apache2

# Disable mod_php and prefork if present
a2dismod php8.3   2>/dev/null || true
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
#  STEP 6 — PHP 8.3-FPM
# =============================================================================
section "Installing PHP 8.3-FPM"

apt-get install -y -qq \
  php8.3-fpm \
  php8.3-cli \
  php8.3-common \
  php8.3-mysql \
  php8.3-redis \
  php8.3-mbstring \
  php8.3-xml \
  php8.3-curl \
  php8.3-zip \
  php8.3-intl \
  php8.3-gd \
  php8.3-imagick \
  php8.3-bcmath \
  php8.3-soap

a2enconf php8.3-fpm
success "PHP 8.3-FPM installed"

# ── FPM pool config ───────────────────────────────────────────────────────────
info "Writing PHP-FPM pool config..."

# Detect actual socket path
FPM_SOCK=$(php8.3-fpm -t 2>&1 | grep -oP '/run/php/[^\s]+\.sock' | head -1 || true)
[[ -z "$FPM_SOCK" ]] && FPM_SOCK="/run/php/php-fpm.sock"

cat > /etc/php/8.3/fpm/pool.d/www.conf <<EOF
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
slowlog = /var/log/php8.3-fpm-slow.log

php_admin_value[memory_limit] = ${PHP_MEMORY_LIMIT}
php_admin_value[max_execution_time] = 30
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[error_log] = /var/log/php8.3-fpm-error.log
php_flag[display_errors] = off
EOF

success "PHP-FPM pool configured"

# ── OPcache + JIT ────────────────────────────────────────────────────────────
info "Writing OPcache + JIT config..."

cat > /etc/php/8.3/fpm/conf.d/99-perf.ini <<EOF
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
EOF

success "OPcache + JIT configured"

# =============================================================================
#  STEP 7 — Redis
# =============================================================================
section "Installing Redis"

apt-get install -y -qq redis-server

cat > /etc/redis/redis.conf <<EOF
bind 127.0.0.1
port 6379
maxmemory ${REDIS_MAX}
maxmemory-policy allkeys-lru
save ""
tcp-backlog 511
tcp-keepalive 300
io-threads ${REDIS_IO_THREADS}
io-threads-do-reads yes
EOF

systemctl enable redis-server
success "Redis installed and configured (maxmemory: ${REDIS_MAX})"

# =============================================================================
#  STEP 8 — Document root and VirtualHost
# =============================================================================
section "Creating VirtualHost for ${DOMAIN}"

# Only create doc root and set permissions if it doesn't exist
if [[ ! -d "${DOC_ROOT}" ]]; then
  mkdir -p "${DOC_ROOT}"
  chown -R www-data:www-data "${DOC_ROOT}"
  chmod 750 "${DOC_ROOT}" 
fi


# Write VirtualHost — port 80, no SSL (certbot later)
cat > "/etc/apache2/sites-available/${DOMAIN}.conf" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${DOC_ROOT}

    <Directory ${DOC_ROOT}>
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
#  STEP 9 — Certbot
# =============================================================================
section "Installing Certbot"

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
cat > /etc/logrotate.d/php8.3-fpm-slow <<EOF
/var/log/php8.3-fpm-slow.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    postrotate
        /usr/lib/php/php8.3-fpm-reopenlogs
    endscript
}
EOF

# =============================================================================
#  STEP 14 — Start and enable all services
# =============================================================================
section "Starting services"

systemctl enable php8.3-fpm apache2 redis-server
systemctl restart redis-server
systemctl restart php8.3-fpm
systemctl restart apache2

# Verify
apache2ctl configtest && success "Apache config syntax OK" || error "Apache config has errors — check above"

# =============================================================================
#  STEP 15 — Health check
# =============================================================================
section "Health check"

echo ""
PHP_VER=$(php -r "echo PHP_VERSION;")
APACHE_VER=$(apache2 -v | grep version | awk '{print $3}')
REDIS_VER=$(redis-server --version | awk '{print $3}')

echo -e "  ${GREEN}PHP${NC}     : ${PHP_VER}"
echo -e "  ${GREEN}Apache${NC}  : ${APACHE_VER}"
echo -e "  ${GREEN}Redis${NC}   : ${REDIS_VER}"
echo -e "  ${GREEN}OPcache${NC} : $(php -r "echo opcache_get_status() ? 'enabled' : 'disabled';" 2>/dev/null || echo 'check manually')"
echo ""
echo -e "  ${GREEN}MPM${NC}     : $(apache2ctl -V 2>/dev/null | grep MPM | awk '{print $3}')"
echo -e "  ${GREEN}Socket${NC}  : $(ls /run/php/php-fpm.sock 2>/dev/null && echo 'exists' || echo 'missing!')"
echo ""

# Memory summary
echo -e "  ${BOLD}RAM budget:${NC}"
echo -e "    FPM workers  : ${PHP_MAX_CHILDREN} × 40 MB = $(( PHP_MAX_CHILDREN * 40 )) MB"
echo -e "    OPcache      : ${OPCACHE_MEM} MB"
echo -e "    Redis        : ${REDIS_MAX}"
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
echo -e "  Doc root     : ${CYAN}${DOC_ROOT}${NC}"
echo -e "  Webmin       : ${CYAN}https://${SERVER_IP}:10000${NC}"
echo ""
echo -e "  ${BOLD}To enable SSL (HTTPS) when DNS is pointing to this server:${NC}"
echo -e "  ${YELLOW}sudo certbot --apache -d ${DOMAIN} -d www.${DOMAIN}${NC}"
echo ""
echo -e "  ${BOLD}To deploy new code without cache issues:${NC}"
echo -e "  ${YELLOW}sudo systemctl reload php8.3-fpm${NC}"
echo ""
echo -e "  ${BOLD}Monitor workers:${NC}"
echo -e "  ${YELLOW}ps --no-headers -o rss -C php-fpm8.3 | awk '{sum+=\$1;n++} END {printf \"workers: %d  avg: %.1fMB  total: %.0fMB\\n\",n,sum/n/1024,sum/1024}'${NC}"
echo ""