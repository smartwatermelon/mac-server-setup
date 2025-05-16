#!/bin/bash
#
# nginx-setup.sh - Nginx web server setup script for Mac Mini M2 'TILSIT' server
#
# This script sets up Nginx web server in a Docker container
#
# Usage: ./nginx-setup.sh [--force]
#   --force: Skip all confirmation prompts
#
# Author: Claude
# Version: 1.0
# Created: 2025-05-13

# Exit on error
set -e

# Configuration variables - adjust as needed
LOG_FILE="/var/log/tilsit-apps.log"
NGINX_CONFIG_DIR="${HOME}/Docker/nginx/config"
NGINX_SITES_DIR="${HOME}/Docker/nginx/sites"
NGINX_HTML_DIR="${HOME}/Docker/nginx/html"
NGINX_LOGS_DIR="${HOME}/Docker/nginx/logs"
NGINX_TIMEZONE="America/Los_Angeles" # Adjust to your timezone

# Parse command line arguments
FORCE=false

for arg in "$@"; do
  case $arg in
    --force)
      FORCE=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Function to log messages to both console and log file
log() {
  local timestamp; timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] $1"
  echo "[$timestamp] $1" | sudo tee -a "$LOG_FILE" >/dev/null
}

# Function to log section headers
section() {
  log "====== $1 ======"
}

# Function to check if a command was successful
check_success() {
  if [ $? -eq 0 ]; then
    log "✅ $1"
  else
    log "❌ $1 failed"
    if [ "$FORCE" = false ]; then
      read -p "Continue anyway? (y/n) " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Exiting due to error"
        exit 1
      fi
    fi
  fi
}

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
  sudo touch "$LOG_FILE"
  sudo chmod 644 "$LOG_FILE"
fi

# Print header
section "Setting Up Nginx Web Server"
log "Running as user: $(whoami)"
log "Date: $(date)"

# Confirm operation if not forced
if [ "$FORCE" = false ]; then
  read -p "This script will set up Nginx web server in a Docker container. Continue? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Setup cancelled by user"
    exit 0
  fi
fi

# Check if Docker is running
section "Checking Docker"
if ! docker info &>/dev/null; then
  log "Docker is not running. Please start Docker Desktop first."
  exit 1
fi
log "Docker is running"

# Create Docker network if it doesn't exist
section "Setting Up Docker Network"
if ! docker network inspect tilsit-network &>/dev/null 2>&1; then
  log "Creating Docker network: tilsit-network"
  docker network create tilsit-network
  check_success "Docker network creation"
else
  log "Docker network tilsit-network already exists"
fi

# Create Nginx directories
section "Setting Up Nginx Directories"
for DIR in "$NGINX_CONFIG_DIR" "$NGINX_SITES_DIR" "$NGINX_HTML_DIR" "$NGINX_LOGS_DIR"; do
  if [ ! -d "$DIR" ]; then
    log "Creating directory: $DIR"
    mkdir -p "$DIR"
    check_success "Directory creation: $DIR"
  else
    log "Directory already exists: $DIR"
  fi
done

# Create default Nginx configuration
if [ ! -f "$NGINX_CONFIG_DIR/nginx.conf" ]; then
  log "Creating default Nginx configuration"
  cat > "$NGINX_CONFIG_DIR/nginx.conf" << 'EOF'
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                     '$status $body_bytes_sent "$http_referer" '
                     '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*.conf;
}
EOF
  check_success "Nginx configuration creation"
else
  log "Nginx configuration already exists"
fi

# Create conf.d directory
if [ ! -d "$NGINX_CONFIG_DIR/conf.d" ]; then
  log "Creating conf.d directory"
  mkdir -p "$NGINX_CONFIG_DIR/conf.d"
  check_success "conf.d directory creation"
fi

# Create sites-enabled directory
if [ ! -d "$NGINX_CONFIG_DIR/sites-enabled" ]; then
  log "Creating sites-enabled directory"
  mkdir -p "$NGINX_CONFIG_DIR/sites-enabled"
  check_success "sites-enabled directory creation"
fi

# Create default site configuration
if [ ! -f "$NGINX_SITES_DIR/default.conf" ]; then
  log "Creating default site configuration"
  cat > "$NGINX_SITES_DIR/default.conf" << 'EOF'
server {
    listen       80;
    listen  [::]:80;
    server_name  localhost;

    #access_log  /var/log/nginx/host.access.log  main;

    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
    }

    #error_page  404              /404.html;

    # redirect server error pages to the static page /50x.html
    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
    }
}
EOF
  check_success "Default site configuration creation"
else
  log "Default site configuration already exists"
fi

# Create a symlink from sites-enabled to the default site if it doesn't exist
if [ ! -f "$NGINX_CONFIG_DIR/sites-enabled/default.conf" ]; then
  log "Creating symlink for default site"
  ln -s "$NGINX_SITES_DIR/default.conf" "$NGINX_CONFIG_DIR/sites-enabled/default.conf"
  check_success "Default site symlink creation"
else
  log "Default site symlink already exists"
fi

# Create default HTML page
if [ ! -f "$NGINX_HTML_DIR/index.html" ]; then
  log "Creating default HTML page"
  cat > "$NGINX_HTML_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
<title>Welcome to TILSIT Server</title>
<style>
    body {
        width: 35em;
        margin: 0 auto;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        line-height: 1.6;
        padding: 2em;
        color: #333;
    }
    h1 {
        color: #377;
        margin-bottom: 0.6em;
    }
    p {
        margin: 1em 0;
    }
</style>
</head>
<body>
<h1>Welcome to TILSIT Server</h1>
<p>If you see this page, the nginx web server is successfully installed and working.</p>

<p>This is the default welcome page which will be replaced with your actual content.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
EOF
  check_success "Default HTML page creation"
else
  log "Default HTML page already exists"
fi

# Check if Nginx container is already running
section "Setting Up Nginx Container"
if docker ps -a --format '{{.Names}}' | grep -q "nginx"; then
  log "Nginx container already exists"
  
  # Check if it's running
  if ! docker ps --format '{{.Names}}' | grep -q "nginx"; then
    log "Starting existing Nginx container"
    docker start nginx
    check_success "Nginx container start"
  else
    log "Nginx container is already running"
  fi
else
  log "Creating and starting Nginx container"
  
  # Run the docker command
  docker run -d \
    --name=nginx \
    --network=tilsit-network \
    --restart=unless-stopped \
    -e TZ="$NGINX_TIMEZONE" \
    -p 80:80 \
    -p 443:443 \
    -v "$NGINX_CONFIG_DIR/nginx.conf":/etc/nginx/nginx.conf:ro \
    -v "$NGINX_CONFIG_DIR/conf.d":/etc/nginx/conf.d:ro \
    -v "$NGINX_CONFIG_DIR/sites-enabled":/etc/nginx/sites-enabled:ro \
    -v "$NGINX_SITES_DIR":/etc/nginx/sites-available:ro \
    -v "$NGINX_HTML_DIR":/usr/share/nginx/html:ro \
    -v "$NGINX_LOGS_DIR":/var/log/nginx \
    nginx:latest
  
  check_success "Nginx container creation"
fi

# Test the Nginx configuration
section "Testing Nginx Configuration"
docker exec -it nginx nginx -t
check_success "Nginx configuration test"

# Provide access instructions
section "Nginx Setup Complete"
log "Nginx web server has been set up successfully"
log "Access your web server at: http://localhost"
log "If accessing from another device, use: http://$(hostname -I | awk '{print $1}')"

# Additional instructions
log "Additional steps you may want to take:"
log "1. Add your website files to: $NGINX_HTML_DIR"
log "2. Configure additional sites in: $NGINX_SITES_DIR"
log "3. Create a symlink in sites-enabled for each site you want to enable"
log "4. Set up SSL certificates for HTTPS access"

exit 0
