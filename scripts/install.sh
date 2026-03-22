#!/bin/bash
# install.sh - Install AI Gateway Management skill
#
# This script:
# 1. Starts the monitor API server on port 18080
# 2. Adds monitor service source to Higress
# 3. Adds monitor route to Higress
# 4. Authorizes manager consumer to access the route

source /opt/hiclaw/scripts/lib/base.sh

SKILL_NAME="ai-gateway-management"
SKILL_DIR="/opt/hiclaw/agent/skills/${SKILL_NAME}"
MONITOR_PORT=18080
CONSOLE_URL="http://127.0.0.1:8001"

: "${HIGRESS_COOKIE_FILE:=/tmp/higress-session-cookie}"
: "${HICLAW_ADMIN_USER:=admin}"
: "${HICLAW_ADMIN_PASSWORD:=admin}"

log "=========================================="
log "Installing ${SKILL_NAME} skill..."
log "=========================================="
log "HIGRESS_COOKIE_FILE: ${HIGRESS_COOKIE_FILE}"
log "HICLAW_ADMIN_USER: ${HICLAW_ADMIN_USER}"

if [ ! -d "${SKILL_DIR}" ]; then
    log "ERROR: Skill directory not found: ${SKILL_DIR}"
    exit 1
fi

higress_login() {
    log "Logging in to Higress Console as '${HICLAW_ADMIN_USER}'..."
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' -c "${HIGRESS_COOKIE_FILE}" -X POST "${CONSOLE_URL}/session/login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"${HICLAW_ADMIN_USER}\",\"password\":\"${HICLAW_ADMIN_PASSWORD}\"}" 2>/dev/null)
    
    if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ]; then
        log "  Login successful (HTTP ${http_code})"
        return 0
    else
        log "  Login failed (HTTP ${http_code})"
        return 1
    fi
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
    
    if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ] || [ "${http_code}" = "204" ] || [ "${http_code}" = "409" ]; then
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

# Add monitor service source (for /ni_status API)
higress_api POST /v1/service-sources "Adding monitor service source" \
    '{"name":"monitor","type":"static","domain":"127.0.0.1:'"${MONITOR_PORT}"'","port":'"${MONITOR_PORT}"'}'

# Add monitor route for /ni_status API (internal use)
higress_api POST /v1/routes "Adding monitor route" \
    '{"name":"ai-gateway-monitor","domains":[],"path":{"matchType":"PRE","matchValue":"/ni_status"},"services":[{"name":"monitor.static","port":'"${MONITOR_PORT}"',"weight":100}]}'

higress_api PUT /v1/routes/ai-gateway-monitor/plugin-instances/key-auth "Enabling key-auth on monitor route" \
    '{"enabled":true,"rawConfigurations":"consumers:\n  - '"${HICLAW_MANAGER_GATEWAY_KEY}"'"}'

# Add Higress Manager UI route for /agm path (LAN/internet access)
# This allows access via http://<server-ip>:8080/agm/
higress_api POST /v1/routes "Adding Higress Manager UI route (/agm)" \
    '{"name":"higress-manager-agm","domains":[],"path":{"matchType":"PRE","matchValue":"/agm"},"services":[{"name":"higress-manager.static","port":18900,"weight":100}],"rewrite":{"enabled":true,"rewriteType":"PREFIX","matchValue":"/agm","replacement":"/"}}'

# Enable basic-auth on /agm route
higress_api PUT /v1/routes/higress-manager-agm/plugin-instances/basic-auth "Enabling basic-auth on /agm route" \
    '{"version":null,"scope":"ROUTE","target":"higress-manager-agm","targets":{"ROUTE":"higress-manager-agm"},"pluginName":"basic-auth","pluginVersion":null,"internal":false,"enabled":true,"rawConfigurations":"consumers:\n  - name: admin\n    credential: '"${HICLAW_ADMIN_USER:-admin}"':'"${HICLAW_ADMIN_PASSWORD}"'"}'

log ""
log "=========================================="
log "${SKILL_NAME} skill installed successfully!"
log "=========================================="
log ""
log "Access URLs:"
log "  Monitor API:  http://aigw-local.hiclaw.io:8080/ni_status/"
log "  Web UI (LAN): http://<your-server-ip>:8080/agm/"
log "  Web UI (dom): http://manager-local.hiclaw.io:8080/"
log ""
log "Authentication:"
log "  Username: ${HICLAW_ADMIN_USER:-admin}"
log "  Password: <your-admin-password>"
log ""
