#!/bin/bash

# Health check script for Caddy home server
# Tests all endpoints and reports status

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

HOSTNAME=${HOSTNAME:-$(hostname -s)}
BASE_URL="https://${HOSTNAME}.local"

echo -e "${BLUE}🏥 Health Check for ${HOSTNAME}.local (Caddy)${NC}"
echo "=============================================="

# Test 1: Root landing page
echo -n "Landing page (/)... "
LANDING_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "${BASE_URL}/")
if echo "${LANDING_CODE}" | grep -q "200"; then
  echo -e "${GREEN}✓ OK${NC}"
else
  echo -e "${RED}✗ FAILED${NC}"
fi

# Test 2: HTTP to HTTPS redirect
echo -n "HTTP redirect... "
REDIRECT_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${HOSTNAME}.local/")
if echo "${REDIRECT_CODE}" | grep -q "301\|302\|308"; then
  echo -e "${GREEN}✓ OK${NC}"
else
  echo -e "${YELLOW}⚠ Check redirect${NC}"
fi

# Test 3: Transmission proxy
echo -n "Transmission proxy (/transmission/)... "
TRANSMISSION_CODE=$(curl -L -k -s -o /dev/null -w "%{http_code}" "${BASE_URL}/transmission/")
if echo "${TRANSMISSION_CODE}" | grep -q -E "200|401|302|409"; then
  echo -e "${GREEN}✓ OK (${TRANSMISSION_CODE})${NC}"
else
  echo -e "${RED}✗ FAILED (${TRANSMISSION_CODE})${NC}"
fi

# Test 4: Romano Synology proxy
echo -n "Romano proxy (/romano/)... "
ROMANO_CODE=$(curl -L -k -s -o /dev/null -w "%{http_code}" "${BASE_URL}/romano/")
if echo "${ROMANO_CODE}" | grep -q -E "200|401|302"; then
  echo -e "${GREEN}✓ OK (${ROMANO_CODE})${NC}"
else
  echo -e "${RED}✗ FAILED (${ROMANO_CODE})${NC}"
fi

# Test 4b: Berkswell Synology proxy
echo -n "Berkswell proxy (/berkswell/)... "
BERKSWELL_CODE=$(curl -L -k -s -o /dev/null -w "%{http_code}" "${BASE_URL}/berkswell/")
if echo "${BERKSWELL_CODE}" | grep -q -E "200|401|302"; then
  echo -e "${GREEN}✓ OK (${BERKSWELL_CODE})${NC}"
else
  echo -e "${RED}✗ FAILED (${BERKSWELL_CODE})${NC}"
fi

# Test 5: CA certificate download
echo -n "CA certificate download... "
CA_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "${BASE_URL}/caddy-root-ca.crt")
if echo "${CA_CODE}" | grep -q "200"; then
  echo -e "${GREEN}✓ OK${NC}"
else
  echo -e "${YELLOW}⚠ Not available${NC}"
fi

# Test 6: Caddy process
echo -n "Caddy process... "
if pgrep caddy >/dev/null; then
  PID=$(pgrep caddy)
  echo -e "${GREEN}✓ Running (PID: ${PID})${NC}"
else
  echo -e "${RED}✗ Not running${NC}"
fi

# Test 7: Certificate status and validity
echo -n "SSL certificate... "
CERT_INFO=$(echo | openssl s_client -connect "${HOSTNAME}.local:443" -servername "${HOSTNAME}.local" 2>/dev/null)
if echo "${CERT_INFO}" | grep -q "Verify return code: 0"; then
  echo -e "${GREEN}✓ Valid & Trusted${NC}"
elif echo "${CERT_INFO}" | grep -q "subject=CN=${HOSTNAME}.local"; then
  # Get certificate expiry
  ENDDATE_LINE=$(echo "${CERT_INFO}" | openssl x509 -noout -enddate 2>/dev/null || true)
  EXPIRY=$(echo "${ENDDATE_LINE}" | cut -d= -f2)
  if [[ -n "${EXPIRY}" ]]; then
    EXPIRY_EPOCH=$(date -j -f "%b %d %H:%M:%S %Y %Z" "${EXPIRY}" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)
    HOURS_LEFT=$(((EXPIRY_EPOCH - NOW_EPOCH) / 3600))

    if [[ ${HOURS_LEFT} -gt 48 ]]; then
      echo -e "${YELLOW}⚠ Self-signed (${HOURS_LEFT}h left)${NC}"
    elif [[ ${HOURS_LEFT} -gt 0 ]]; then
      echo -e "${YELLOW}⚠ Expiring soon (${HOURS_LEFT}h left)${NC}"
    else
      echo -e "${RED}✗ Expired${NC}"
    fi
  else
    echo -e "${YELLOW}⚠ Self-signed${NC}"
  fi
else
  echo -e "${RED}✗ Invalid${NC}"
fi

# Test 8: Deployed configuration file status
DEPLOY_CADDYFILE="/Users/__OPERATOR_USERNAME__/.config/caddy/Caddyfile"
echo -n "Configuration... "
if [[ -f "${DEPLOY_CADDYFILE}" ]]; then
  echo -e "${GREEN}✓ Deployed (${DEPLOY_CADDYFILE})${NC}"
else
  echo -e "${RED}✗ Missing (${DEPLOY_CADDYFILE})${NC}"
fi

echo ""
echo -e "${BLUE}📊 System Information:${NC}"
echo "  Server: ${BASE_URL}"
CADDY_VERSION=$(caddy version 2>/dev/null || echo 'Not found')
echo "  Caddy version: ${CADDY_VERSION}"
UPTIME_RAW=$(uptime)
UPTIME_AWK=$(echo "${UPTIME_RAW}" | awk '{print $3,$4}')
UPTIME="${UPTIME_AWK//,/}"
echo "  Uptime: ${UPTIME}"

echo ""
echo -e "${BLUE}📄 Log locations:${NC}"
echo "  Access: /usr/local/var/log/caddy/access.log"
echo "  Errors: /Users/__OPERATOR_USERNAME__/.local/state/caddy/caddy-error.log"

echo ""
echo -e "${BLUE}🔧 Quick commands:${NC}"
echo "  Restart: sudo launchctl kickstart -k system/com.caddyserver.caddy"
echo "  Logs:    tail -f /usr/local/var/log/caddy/access.log"
echo "  Stop:    sudo launchctl bootout system/com.caddyserver.caddy"
