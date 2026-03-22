# LAMP Stack Auto-Installer

> High-performance PHP server setup for Ubuntu 24.04 — fully automated, hardware-aware, production-ready.

---

## What it does

A single bash script that detects your server's hardware and installs a fully tuned LAMP stack with every configuration value calculated automatically for your CPU count and available RAM. No manual tuning required.

When the script finishes, it runs a three-stage performance benchmark and shows you exactly how your server is performing.

---

## Stack

| Component | Version | Role |
|---|---|---|
| **Apache2** | 2.4.x | Web server (MPM Event) |
| **PHP-FPM** | 8.3 | FastCGI process manager |
| **OPcache + JIT** | built-in | Bytecode + JIT compilation |
| **Redis** | 7.x | Object cache + session store |
| **Certbot** | latest | SSL certificate management |
| **Webmin** | latest | Server administration UI |
| **ImageMagick** | latest | Image processing |
| **Midnight Commander** | latest | Terminal file manager |
| **ncdu** | latest | Disk usage analyzer |

---

## Requirements

- Ubuntu **24.04 LTS**
- Root or sudo access
- A domain name pointed at the server (for SSL — optional at install time)
- Outbound internet access

---

## Usage

```bash
# Download the script
wget https://your-repo/install-lamp-stack.sh

# Make it executable
chmod +x install-lamp-stack.sh

# Run as root
sudo bash install-lamp-stack.sh
```

The script will ask for your domain name once, then handle everything else automatically.

---

## What gets configured

### Hardware detection

The script reads your actual CPU and RAM at runtime and calculates all values before touching anything:

```
Detected: 8 vCPU | 16 GB RAM | 160 GB disk

  PHP-FPM  max_children      = 100
  PHP-FPM  start_servers     = 16
  PHP      memory_limit      = 256M
  OPcache  memory            = 384 MB
  OPcache  JIT buffer        = 128M
  Redis    maxmemory         = 1gb
  Apache   MaxRequestWorkers = 200
  Apache   StartServers      = 8
  Hugepages                  = 256
```

### Configuration values by hardware tier

| Setting | 2 vCPU / 4 GB | 4 vCPU / 8 GB | 8 vCPU / 16 GB | 12 vCPU / 24 GB | 16+ vCPU / 32+ GB |
|---|---|---|---|---|---|
| `pm.max_children` | 25 | 50 | 100 | 150 | 200 |
| `pm.start_servers` | 4 | 10 | 16 | 24 | 32 |
| `memory_limit` | 128M | 256M | 256M | 256M | 256M |
| `opcache.memory_consumption` | 128 MB | 256 MB | 384 MB | 512 MB | 512 MB |
| `opcache.jit_buffer_size` | 64M | 128M | 128M | 256M | 256M |
| `maxmemory` Redis | 256mb | 512mb | 1gb | 2gb | 4gb |
| `MaxRequestWorkers` | 50 | 100 | 200 | 300 | 400 |
| `StartServers` | 2 | 4 | 8 | 12 | 16 |
| `nr_hugepages` | 64 | 128 | 256 | 384 | 512 |
| Redis `io-threads` | 1 | 2 | 4 | 6 | 8 |
| Benchmark concurrency | 20 | 50 | 100 | 150 | 200 |

---

## Installation steps

The script runs 17 steps and reports progress at each one:

```
══════════════════════════════════════════
  Step 1  — Detecting hardware
  Step 2  — Domain configuration
  Step 3  — System update
  Step 4  — Installing utilities
  Step 5  — Installing Apache2
  Step 6  — Installing PHP 8.3-FPM
  Step 7  — Installing Redis
  Step 8  — Creating VirtualHost
  Step 9  — Installing Certbot
  Step 10 — Installing Webmin
  Step 11 — Applying kernel tuning
  Step 12 — Moving PHP sessions to tmpfs
  Step 13 — Log rotation
  Step 14 — UFW firewall
  Step 15 — Starting services
  Step 16 — Health check
  Step 17 — Performance benchmark
══════════════════════════════════════════
```

---

## Performance benchmark

After installation, three tests run automatically against the local server:

### Test 1 — Static HTML

Measures raw Apache throughput with no PHP involved. Sets the ceiling for what the web server can deliver.

### Test 2 — PHP-FPM + OPcache

Hits a PHP endpoint that exercises OPcache, JIT, and the FPM unix socket. This is the number that reflects real application performance.

### Test 3 — Redis latency

Runs `redis-benchmark` with pipelining for `PING`, `SET`, and `GET`. Confirms the cache layer is healthy before you deploy.

Sample output:

```
  Test 1/3 — Static HTML (Apache raw throughput)
  10000 requests · 100 concurrent · keep-alive

    Requests/sec  : 18432.10
    Mean latency  : 5.42 ms
    p99 latency   : 12 ms
    Failed        : 0

  Test 2/3 — PHP-FPM + OPcache (application throughput)
  10000 requests · 100 concurrent · keep-alive

    Requests/sec  : 6821.44
    Mean latency  : 14.65 ms
    p99 latency   : 31 ms
    Throughput    : 4823.1 KB/s
    Failed        : 0

  Test 3/3 — Redis latency (cache round-trip)

    PING          : 892341.50 req/s
    SET           : 748502.00 req/s
    GET           : 810372.00 req/s

  Worker memory after benchmark:
    FPM workers: 38 active  |  avg 32.4 MB  |  total 1231 MB
    RAM usage  : used 2.8G  |  free 11.4G   |  available 12.9G

  Score:
    EXCELLENT — server is performing at full capacity
```

---

## VirtualHost

The script creates a port 80 VirtualHost (no SSL). SSL is intentionally left for you to enable afterwards so you control the timing.

Document root is created at `/home/yourdomain.com/`.

```apache
<VirtualHost *:80>
    ServerName yourdomain.com
    ServerAlias www.yourdomain.com
    DocumentRoot /home/yourdomain.com

    <Directory /home/yourdomain.com>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch "\.php$">
        SetHandler "proxy:unix:/run/php/php-fpm.sock|fcgi://localhost"
    </FilesMatch>
    ...
</VirtualHost>
```

---

## Enabling SSL after installation

Once your domain's DNS is pointing to the server:

```bash
sudo certbot --apache -d yourdomain.com -d www.yourdomain.com
```

Certbot will obtain the certificate, update the VirtualHost automatically, and set up auto-renewal.

---

## Firewall

UFW is configured automatically:

| Port | Protocol | Service |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | HTTP |
| 443 | TCP | HTTPS |
| 10000 | TCP | Webmin |

---

## Key performance decisions

**MPM Event over Prefork** — Apache's async event model handles keep-alive connections without blocking a worker per connection. Uses far less memory under load than the legacy prefork model.

**PHP-FPM over mod_php** — PHP runs as a separate process pool communicating over a unix socket. Workers can be recycled, tuned, and monitored independently of Apache.

**Unix socket over TCP** — FPM communicates with Apache via `/run/php/php-fpm.sock` rather than `127.0.0.1:9000`. Eliminates TCP stack overhead for every PHP request.

**OPcache with validate_timestamps = 0** — PHP files are compiled once and cached in shared memory permanently. No filesystem stat calls on every request. Cache is cleared with `sudo systemctl reload php8.3-fpm`.

**JIT tracing mode** — PHP 8.x JIT compiles hot code paths to native machine code at runtime. The `tracing` mode gives the best results for typical web workloads.

**Redis for sessions** — PHP sessions are stored in Redis instead of disk. Eliminates session file locking bottlenecks under concurrent load.

**tmpfs for session fallback** — Even if Redis is bypassed, `/var/lib/php/sessions` is mounted in RAM so session I/O never hits the SSD.

**Linux huge pages** — OPcache maps its shared memory using 2MB huge pages instead of 4KB pages. Reduces TLB pressure on heavily loaded servers.

---

## After deployment

### Deploy new code without cache issues

```bash
# After uploading new PHP files — clears OPcache gracefully
sudo systemctl reload php8.3-fpm
```

### Monitor FPM workers in real time

```bash
watch -n2 "ps --no-headers -o rss -C php-fpm8.3 \
  | awk '{sum+=\$1;n++} END \
  {printf \"workers: %d  avg: %.1fMB  total: %.0fMB\n\",n,sum/n/1024,sum/1024}'"
```

### Watch for slow DB queries

```bash
tail -f /var/log/php8.3-fpm-slow.log
```

### Check memory pressure

```bash
free -h
# Available column should stay above 15% of total RAM under normal load
```

### Access Webmin

```
https://your-server-ip:10000
```

Log in with your Linux root credentials.

---

## Troubleshooting

**Apache fails to start**

```bash
sudo apache2ctl configtest     # shows the exact broken line
sudo journalctl -xeu apache2.service --no-pager | tail -30
```

**PHP-FPM fails to start**

```bash
sudo systemctl status php8.3-fpm
sudo tail -30 /var/log/php8.3-fpm.log
# Common cause: opcache.preload pointing to a file that doesn't exist
# Fix: comment out opcache.preload in /etc/php/8.3/fpm/conf.d/99-perf.ini
```

**503 Service Unavailable**

```bash
ls -la /run/php/          # confirm socket exists
sudo systemctl status php8.3-fpm
```

**Old code still running after deploy**

```bash
sudo systemctl reload php8.3-fpm    # flushes OPcache
```

**403 Forbidden**

```bash
# Check the Directory block in your VirtualHost has Require all granted
# Check ownership of document root:
sudo chown -R www-data:www-data /home/yourdomain.com
sudo chmod 750 /home/yourdomain.com
```

---

## License

MIT — free to use, modify, and distribute.
