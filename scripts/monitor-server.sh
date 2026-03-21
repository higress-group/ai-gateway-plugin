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
    
    python3 << 'PYTHON_SCRIPT' > "${LOG_FILE}" 2>&1 &
import http.server
import json
import os
import subprocess
import socketserver
from datetime import datetime
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get('MONITOR_PORT', 18080))
AGENTS_DIR = '/root/hiclaw-fs/agents'

class MonitorHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass
    
    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
        self.end_headers()
    
    def do_GET(self):
        path = urlparse(self.path).path
        
        if path == '/ni_status/metrics':
            self.get_metrics()
        elif path == '/ni_status/health':
            self.send_json({'status': 'healthy'})
        elif path == '/ni_status/assignment/manager':
            self.get_assignment('manager')
        elif path.startswith('/ni_status/assignment/workers/'):
            worker = path.split('/')[-1]
            self.get_assignment(worker)
        else:
            self.send_json({'error': 'Not found'}, 404)
    
    def do_POST(self):
        path = urlparse(self.path).path
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode() if content_length > 0 else '{}'
        
        try:
            data = json.loads(body)
        except:
            data = {}
        
        if path == '/ni_status/reload':
            self.reload_config(data)
        else:
            self.send_json({'error': 'Not found'}, 404)
    
    def do_PUT(self):
        path = urlparse(self.path).path
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode() if content_length > 0 else '{}'
        
        try:
            data = json.loads(body)
        except:
            self.send_json({'error': 'Invalid JSON'}, 400)
            return
        
        if path == '/ni_status/assignment/manager':
            self.set_assignment('manager', data)
        elif path.startswith('/ni_status/assignment/workers/'):
            worker = path.split('/')[-1]
            self.set_assignment(worker, data)
        else:
            self.send_json({'error': 'Not found'}, 404)
    
    def get_metrics(self):
        try:
            cpu = subprocess.check_output(
                "top -bn1 | grep 'Cpu(s)' | awk '{print $2}' | cut -d'%' -f1",
                shell=True, text=True
            ).strip() or '0'
            cpu = float(cpu) if cpu.replace('.','').isdigit() else 0
        except:
            cpu = 0
        
        try:
            mem_info = subprocess.check_output('free | grep Mem', shell=True, text=True).split()
            mem = int(int(mem_info[2]) / int(mem_info[1]) * 100)
        except:
            mem = 0
        
        try:
            connections = int(subprocess.check_output(
                'netstat -an | grep -c ESTABLISHED', shell=True, text=True
            ))
        except:
            connections = 0
        
        try:
            rpm = int(open('/tmp/rpm-counter').read())
        except:
            rpm = 0
        
        self.send_json({
            'cpu': int(cpu),
            'memory': mem,
            'connections': connections,
            'rpm': rpm,
            'timestamp': datetime.utcnow().isoformat() + 'Z'
        })
    
    def reload_config(self, data):
        target = data.get('target', 'manager')
        
        if target == 'manager':
            try:
                subprocess.run(['pkill', '-HUP', '-f', 'openclaw.*manager'], check=False)
            except:
                pass
            
            try:
                subprocess.run(['curl', '-s', '-X', 'POST', 'http://127.0.0.1:18799/api/reload'], check=False)
            except:
                pass
        
        self.send_json({'status': 'reloaded', 'target': target})
    
    def get_assignment(self, name):
        model_file = os.path.join(AGENTS_DIR, name, 'model.json')
        
        if os.path.exists(model_file):
            with open(model_file) as f:
                self.send_json(json.load(f))
        else:
            self.send_json({'provider': 'default', 'model': 'default'})
    
    def set_assignment(self, name, data):
        model_dir = os.path.join(AGENTS_DIR, name)
        os.makedirs(model_dir, exist_ok=True)
        
        model_file = os.path.join(model_dir, 'model.json')
        data['updatedAt'] = datetime.utcnow().isoformat() + 'Z'
        
        with open(model_file, 'w') as f:
            json.dump(data, f, indent=2)
        
        self.send_json({'status': 'saved', 'name': name})

class ReuseAddrServer(socketserver.TCPServer):
    allow_reuse_address = True

with ReuseAddrServer(('', PORT), MonitorHandler) as httpd:
    print(f'Monitor server running on port {PORT}')
    httpd.serve_forever()
PYTHON_SCRIPT

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
