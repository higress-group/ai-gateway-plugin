#!/bin/bash
# install.sh - Install AI Gateway Management skill
#
# This script:
# 1. Starts the monitor API server on port 18080
# 2. Adds monitor service source to Higress
# 3. Adds monitor route to Higress
# 4. Authorizes manager consumer to access the route

set -e
source /opt/hiclaw/scripts/lib/base.sh

SKILL_NAME="ai-gateway-management"
SKILL_DIR="/opt/hiclaw/agent/skills/${SKILL_NAME}"
MONITOR_PORT=18080
CONSOLE_URL="http://127.0.0.1:8001"
HIGRESS_COOKIE_FILE="${HIGRESS_COOKIE_FILE:-/tmp/higress-cookie.txt}"

log "=========================================="
log "Installing ${SKILL_NAME} skill..."
log "=========================================="

if [ ! -d "${SKILL_DIR}" ]; then
    log "ERROR: Skill directory not found: ${SKILL_DIR}"
    exit 1
fi

higress_login() {
    log "Logging in to Higress Console..."
    curl -s -c "${HIGRESS_COOKIE_FILE}" -X POST "${CONSOLE_URL}/session/login" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"${HICLAW_ADMIN_USER:-admin}\",\"password\":\"${HICLAW_ADMIN_PASSWORD}\"}" > /dev/null
}

higress_api() {
    local method="$1"
    local path="$2"
    local message="$3"
    local body="$4"
    
    log "${message}..."
    
    local response
    if [ -n "${body}" ]; then
        response=$(curl -s -w '\n%{http_code}' -X "${method}" "${CONSOLE_URL}${path}" \
            -b "${HIGRESS_COOKIE_FILE}" \
            -H 'Content-Type: application/json' \
            -d "${body}" 2>/dev/null)
    else
        response=$(curl -s -w '\n%{http_code}' -X "${method}" "${CONSOLE_URL}${path}" \
            -b "${HIGRESS_COOKIE_FILE}" 2>/dev/null)
    fi
    
    local http_code=$(echo "$response" | tail -1)
    
    if [ "${http_code}" = "401" ] || [ "${http_code}" = "403" ]; then
        higress_login
        if [ -n "${body}" ]; then
            response=$(curl -s -w '\n%{http_code}' -X "${method}" "${CONSOLE_URL}${path}" \
                -b "${HIGRESS_COOKIE_FILE}" \
                -H 'Content-Type: application/json' \
                -d "${body}" 2>/dev/null)
        else
            response=$(curl -s -w '\n%{http_code}' -X "${method}" "${CONSOLE_URL}${path}" \
                -b "${HIGRESS_COOKIE_FILE}" 2>/dev/null)
        fi
        http_code=$(echo "$response" | tail -1)
    fi
    
    if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ] || [ "${http_code}" = "204" ]; then
        log "  OK (${http_code})"
        return 0
    else
        log "  WARNING: HTTP ${http_code}"
        return 1
    fi
}

log ""
log "Step 1: Starting monitor API server..."
bash "${SKILL_DIR}/scripts/monitor-server.sh" start

sleep 2
if curl -s "http://127.0.0.1:${MONITOR_PORT}/ni_status/health" > /dev/null 2>&1; then
    log "  Monitor server is healthy"
else
    log "  WARNING: Monitor server health check failed"
fi

log ""
log "Step 2: Configuring Higress..."
higress_login

higress_api POST /v1/service-sources "Adding monitor service source" \
    '{"name":"monitor","type":"dns","domain":"127.0.0.1","port":'"${MONITOR_PORT}"'}'

higress_api POST /v1/routes "Adding monitor route" \
    '{"name":"ai-gateway-monitor","path":{"matchType":"PRE","matchValue":"/ni_status"},"services":[{"name":"monitor","port":'"${MONITOR_PORT}"',"weight":100}]}'

higress_api PUT /v1/routes/ai-gateway-monitor/plugin-instances/key-auth "Enabling key-auth on monitor route" \
    '{"enabled":true,"rawConfigurations":"consumers:\n  - '"${HICLAW_MANAGER_GATEWAY_KEY}"'"}'

log ""
log "=========================================="
log "${SKILL_NAME} skill installed successfully!"
log "=========================================="
log ""
log "Monitor API: http://aigw-local.hiclaw.io:8080/ni_status/"
log "Web UI:      http://manager-local.hiclaw.io:8080/"
log ""
