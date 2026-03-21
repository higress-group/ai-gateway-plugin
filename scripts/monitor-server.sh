#!/bin/bash
# monitor-server.sh - Monitor API server for AI Gateway Management skill
#
# Provides REST API endpoints for:
# - /ni_status/metrics - System metrics (CPU, memory, connections)
# - /ni_status/reload - Reload configuration
# - /ni_status/assignment/* - Model assignments

set -e
source /opt/hiclaw/scripts/lib/base.sh

MONITOR_PORT="${MONITOR_PORT:-18080}"
PID_FILE="/tmp/monitor-server.pid"
LOG_FILE="/tmp/monitor-server.log"

start_server() {
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat ${PID_FILE})" 2>/dev/null; then
        log "Monitor server already running (PID: $(cat ${PID_FILE}))"
        return 0
    fi

    log "Starting monitor server on port ${MONITOR_PORT}..."
    
    cat > /tmp/monitor-api.sh << 'SERVERSCRIPT'
#!/bin/bash
# Simple HTTP server using netcat

PORT="${MONITOR_PORT:-18080}"
LOG_FILE="/tmp/monitor-server.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

get_metrics() {
    local cpu_usage=$(top -bn1 2>/dev/null | grep "Cpu(s)" | sed 's/.*, *\([0-9.]*\)%* id.*/\1/' | awk '{print 100 - $1}' | cut -d. -f1 2>/dev/null || echo "0")
    local mem_usage=$(free 2>/dev/null | grep Mem | awk '{print int($3/$2 * 100)}' 2>/dev/null || echo "0")
    local connections=$(netstat -an 2>/dev/null | grep -c ESTABLISHED 2>/dev/null || echo "0")
    local rpm=$(cat /tmp/rpm-counter 2>/dev/null || echo "0")
    
    local json="{"
    json+="\"cpu\":${cpu_usage},"
    json+="\"memory\":${mem_usage},"
    json+="\"connections\":${connections},"
    json+="\"rpm\":${rpm},"
    json+="\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    json+="}"
    
    echo -e "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Type: application/json\r\n\r\n${json}"
}

reload_config() {
    local body="$1"
    local target=$(echo "$body" | jq -r '.target // "manager"' 2>/dev/null)
    
    if [ "$target" = "manager" ]; then
        local openclaw_pid=$(pgrep -f "openclaw.*manager" 2>/dev/null | head -1)
        if [ -n "$openclaw_pid" ]; then
            kill -HUP "$openclaw_pid" 2>/dev/null || true
        fi
        
        curl -s -X POST "http://127.0.0.1:18799/api/reload" 2>/dev/null || true
        
        echo -e "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Type: application/json\r\n\r\n{\"status\":\"reloaded\",\"target\":\"manager\"}"
    else
        echo -e "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Type: application/json\r\n\r\n{\"status\":\"notified\",\"target\":\"$target\"}"
    fi
}

handle_assignment() {
    local method="$1"
    local path="$2"
    local body="$3"
    
    local cors_headers="Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, PUT, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type"
    
    if [ "$method" = "OPTIONS" ]; then
        echo -e "HTTP/1.1 200 OK\r\n${cors_headers}\r\nContent-Length: 0\r\n\r\n"
        return
    fi
    
    local entity=""
    local name=""
    
    if [[ "$path" == /ni_status/assignment/manager* ]]; then
        entity="manager"
        name="manager"
    elif [[ "$path" == /ni_status/assignment/workers/* ]]; then
        entity="worker"
        name=$(echo "$path" | sed 's|/ni_status/assignment/workers/||' | cut -d'/' -f1)
    fi
    
    local model_file="/root/hiclaw-fs/agents/${name}/model.json"
    
    if [ "$method" = "GET" ]; then
        if [ -f "$model_file" ]; then
            local content=$(cat "$model_file")
            echo -e "HTTP/1.1 200 OK\r\n${cors_headers}\r\nContent-Type: application/json\r\n\r\n${content}"
        else
            echo -e "HTTP/1.1 200 OK\r\n${cors_headers}\r\nContent-Type: application/json\r\n\r\n{\"provider\":\"default\",\"model\":\"default\"}"
        fi
    elif [ "$method" = "PUT" ]; then
        mkdir -p "$(dirname "$model_file")"
        local json_body=$(echo "$body" | sed -n '/^{/,/^}/p')
        json_body=$(echo "$json_body" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {updatedAt: $ts}' 2>/dev/null || echo "$json_body")
        echo "$json_body" > "$model_file"
        echo -e "HTTP/1.1 200 OK\r\n${cors_headers}\r\nContent-Type: application/json\r\n\r\n{\"status\":\"saved\"}"
    else
        echo -e "HTTP/1.1 405 Method Not Allowed\r\n${cors_headers}\r\n\r\n"
    fi
}

handle_request() {
    local request="$1"
    local method=$(echo "$request" | head -1 | awk '{print $1}')
    local path=$(echo "$request" | head -1 | awk '{print $2}')
    
    local cors_headers="Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization"
    
    if [ "$method" = "OPTIONS" ]; then
        echo -e "HTTP/1.1 200 OK\r\n${cors_headers}\r\nContent-Length: 0\r\n\r\n"
        return
    fi
    
    local body=$(echo "$request" | sed -n '/^\{/,$p' | head -1)
    
    case "$path" in
        /ni_status/metrics)
            get_metrics
            ;;
        /ni_status/reload)
            reload_config "$body"
            ;;
        /ni_status/assignment/manager|/ni_status/assignment/manager/*)
            handle_assignment "$method" "$path" "$body"
            ;;
        /ni_status/assignment/workers/*)
            handle_assignment "$method" "$path" "$body"
            ;;
        /ni_status/health)
            echo -e "HTTP/1.1 200 OK\r\n${cors_headers}\r\nContent-Type: application/json\r\n\r\n{\"status\":\"healthy\"}"
            ;;
        *)
            echo -e "HTTP/1.1 404 Not Found\r\n${cors_headers}\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Not found\"}"
            ;;
    esac
}

# Main loop using socat
export MONITOR_PORT
export -f log get_metrics reload_config handle_assignment handle_request

if command -v socat >/dev/null 2>&1; then
    socat TCP-LISTEN:${PORT},fork,reuseaddr SYSTEM:'bash -c '\''read -r line; request="$line"; while read -r line && [ -n "$line" ]; do request+=$'"'"'\n'"'"'$line; done; request+=$'"'"'\n'"'"'; while read -t 0.1 -r line; do request+=$'"'"'\n'"'"'$line; done; handle_request "$request"'\''' 2>>"$LOG_FILE"
else
    log "ERROR: socat not installed"
    exit 1
fi
SERVERSCRIPT
    
    chmod +x /tmp/monitor-api.sh
    
    nohup bash /tmp/monitor-api.sh > "${LOG_FILE}" 2>&1 &
    local pid=$!
    echo $pid > "${PID_FILE}"
    
    log "Monitor server started (PID: $pid)"
}

stop_server() {
    if [ -f "${PID_FILE}" ]; then
        local pid=$(cat "${PID_FILE}")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            log "Monitor server stopped (PID: $pid)"
        fi
        rm -f "${PID_FILE}"
    fi
}

status_server() {
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat ${PID_FILE})" 2>/dev/null; then
        log "Monitor server running (PID: $(cat ${PID_FILE}))"
        return 0
    else
        log "Monitor server not running"
        return 1
    fi
}

case "${1:-start}" in
    start)   start_server ;;
    stop)    stop_server ;;
    status)  status_server ;;
    restart) stop_server; sleep 1; start_server ;;
    *)       echo "Usage: $0 {start|stop|status|restart}" ;;
esac
