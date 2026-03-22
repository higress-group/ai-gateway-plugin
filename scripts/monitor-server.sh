#!/bin/bash
# monitor-server.sh - Monitor API server for AI Gateway Management skill
#
# Provides REST API endpoints for:
# - /ni_status/metrics - System metrics (CPU, memory, connections)
# - /ni_status/reload - Reload configuration
# - /ni_status/set-model - Set model for manager or worker
# - /ni_status/assignment/* - Model assignments

MONITOR_PORT="${MONITOR_PORT:-18080}"
PID_FILE="/tmp/monitor-server.pid"
LOG_FILE="/tmp/monitor-server.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

start_server() {
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat ${PID_FILE})" 2>/dev/null; then
        log "Monitor server already running (PID: $(cat ${PID_FILE}))"
        return 0
    fi

    log "Starting monitor server on port ${MONITOR_PORT}..."
    
    # Export environment variables for Python
    export HIGRESS_COOKIE_FILE="${HIGRESS_COOKIE_FILE:-/tmp/higress-session-cookie}"
    export HICLAW_ADMIN_USER="${HICLAW_ADMIN_USER:-admin}"
    export HICLAW_ADMIN_PASSWORD="${HICLAW_ADMIN_PASSWORD:-admin}"
    export MANAGER_GATEWAY_KEY="${HICLAW_MANAGER_GATEWAY_KEY:-}"
    export HICLAW_MANAGER_GATEWAY_KEY="${HICLAW_MANAGER_GATEWAY_KEY:-}"
    
    log "MANAGER_GATEWAY_KEY length: ${#MANAGER_GATEWAY_KEY}"
    log "HICLAW_MANAGER_GATEWAY_KEY length: ${#HICLAW_MANAGER_GATEWAY_KEY}"
    
    python3 - << 'EOF' >> "${LOG_FILE}" 2>&1 &
import http.server
import json
import os
import subprocess
import socketserver
from datetime import datetime
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get('MONITOR_PORT', 18080))
AGENTS_DIR = '/root/hiclaw-fs/agents'
OPENCLAW_CONFIG = '/root/manager-workspace/openclaw.json'
HICLAW_FS = '/root/hiclaw-fs'

def run_cmd(cmd, check=False):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        if check and result.returncode != 0:
            return None, result.stderr
        return result.stdout.strip(), None
    except Exception as e:
        return None, str(e)

def ensure_higress_login():
    cookie_file = os.environ.get('HIGRESS_COOKIE_FILE') or '/tmp/higress-session-cookie'
    admin_user = os.environ.get('HICLAW_ADMIN_USER') or 'admin'
    admin_pass = os.environ.get('HICLAW_ADMIN_PASSWORD') or 'admin'
    
    print('[DEBUG] ensure_higress_login: cookie_file=' + str(cookie_file))
    print('[DEBUG] ensure_higress_login: admin_user=' + str(admin_user))
    print('[DEBUG] ensure_higress_login: admin_pass length=' + str(len(admin_pass)))
    print('[DEBUG] ensure_higress_login: cookie exists=' + str(os.path.exists(cookie_file)))
    
    if os.path.exists(cookie_file) and os.path.getsize(cookie_file) > 0:
        print('[DEBUG] Testing existing cookie...')
        test_result, _ = run_cmd('curl -s -b "' + cookie_file + '" "http://127.0.0.1:8001/v1/ai/providers"')
        if test_result and '<!DOCTYPE html>' not in test_result:
            print('[DEBUG] Existing cookie is valid')
            return True
        else:
            print('[DEBUG] Existing cookie is invalid, re-login required')
    
    if not admin_user or not admin_pass:
        print('[ERROR] Missing admin credentials: user=' + str(admin_user) + ', pass=' + ('set' if admin_pass else 'empty'))
        return False
    
    print('[DEBUG] Logging in to Higress Console as ' + admin_user)
    login_cmd = 'curl -s -X POST "http://127.0.0.1:8001/session/login" -H "Content-Type: application/json" -c "' + cookie_file + '" -d \'{"username":"' + admin_user + '","password":"' + admin_pass + '"}\''
    print('[DEBUG] Login command: ' + login_cmd)
    result, err = run_cmd(login_cmd)
    result_str = str(result)[:200] if result else 'None'
    print('[DEBUG] Login result: ' + result_str)
    if err:
        print('[DEBUG] Login error: ' + str(err))
    
    if os.path.exists(cookie_file):
        print('[DEBUG] Cookie file created, size=' + str(os.path.getsize(cookie_file)))
        if os.path.getsize(cookie_file) > 0:
            return True
    
    print('[ERROR] Failed to login to Higress Console')
    return False

def higress_api(method, path, data=None):
    cookie_file = os.environ.get('HIGRESS_COOKIE_FILE') or '/tmp/higress-session-cookie'
    
    if not ensure_higress_login():
        return None, 'Failed to login to Higress Console'
    
    cmd = 'curl -s -m 30 -X ' + method + ' "http://127.0.0.1:8001' + path + '"'
    cmd += ' -H "Content-Type: application/json"'
    cmd += ' -b "' + cookie_file + '"'
    if data:
        data_str = json.dumps(data).replace("'", "'\"'\"'")
        cmd += " -d '" + data_str + "'"
    
    result, err = run_cmd(cmd)
    if err:
        return None, err
    if not result:
        return None, 'Empty response'
    
    if '<!DOCTYPE html>' in result:
        return None, 'Session expired (got HTML)'
    
    try:
        parsed = json.loads(result)
        if isinstance(parsed, dict):
            if parsed.get('success') == False:
                return None, parsed.get('message', 'API error')
            if parsed.get('code') and parsed.get('code') != 0:
                return None, parsed.get('message', 'API error: ' + str(parsed.get('code')))
        return parsed, None
    except Exception as e:
        if '404' in result or 'Not Found' in result:
            return None, 'Not found'
        if '401' in result or 'Unauthorized' in result:
            return None, 'Unauthorized'
        return result, None

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
        elif path == '/ni_status/providers':
            self.list_providers()
        elif path == '/ni_status/route':
            self.get_route()
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
        elif path == '/ni_status/set-model':
            self.set_model(data)
        elif path == '/ni_status/test-provider':
            self.test_provider(data)
        elif path == '/ni_status/create-provider':
            self.create_provider(data)
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
    
    def list_providers(self):
        providers_data, err = higress_api('GET', '/v1/ai/providers')
        if err:
            self.send_json({'success': False, 'error': 'Failed to list providers: ' + err}, 500)
            return
        
        providers = providers_data.get('data', providers_data) if providers_data else []
        self.send_json({'success': True, 'providers': providers})
    
    def get_route(self):
        routes_data, err = higress_api('GET', '/v1/ai/routes')
        if err:
            self.send_json({'success': False, 'error': 'Failed to get routes: ' + err}, 500)
            return
        
        routes = routes_data.get('data', routes_data) if routes_data else []
        # Filter AI routes: exclude MCP routes and default-ai-route
        ai_routes = [r for r in routes if r.get('name', '').endswith('-ai-route') and r.get('name') != 'default-ai-route']
        
        self.send_json({'success': True, 'routes': ai_routes})
    
    def create_provider(self, data):
        provider_name = data.get('name')
        provider_type = data.get('type', 'openai')
        api_key = data.get('apiKey')
        base_url = data.get('baseUrl')
        
        if not provider_name or not api_key:
            self.send_json({'success': False, 'error': 'Provider name and API key are required'}, 400)
            return
        
        provider_body = {
            'name': provider_name,
            'type': provider_type,
            'tokens': [api_key]
        }
        
        if base_url:
            provider_body['rawConfigs'] = {
                '_custom': 'true',
                'openaiCustomUrl': base_url
            }
            svc_name = provider_name + '.dns'
            provider_body['rawConfigs']['openaiCustomServiceName'] = svc_name
            provider_body['rawConfigs']['openaiCustomServicePort'] = 443
            
            svc_body = {'type': 'dns', 'name': svc_name, 'domain': base_url.replace('https://', '').replace('http://', '').split('/')[0], 'port': 443}
            if ':' in svc_body['domain']:
                parts = svc_body['domain'].split(':')
                svc_body['domain'] = parts[0]
                svc_body['port'] = int(parts[1])
            
            higress_api('POST', '/v1/service-sources', svc_body)
        
        result, err = higress_api('POST', '/v1/ai/providers', provider_body)
        if err:
            self.send_json({'success': False, 'error': 'Failed to create provider: ' + err}, 500)
            return
        
        # Use provider-specific route name format: {provider}-ai-route
        route_name = provider_name + '-ai-route'
        
        # Use configured AI Gateway domain
        ai_gateway_domain = os.environ.get('HICLAW_AI_GATEWAY_DOMAIN', 'aigw-local.hiclaw.io')
        
        new_route = {
            'name': route_name,
            'domains': [ai_gateway_domain],
            'pathPredicate': {'matchType': 'PRE', 'matchValue': '/', 'caseSensitive': False},
            'authConfig': {'enabled': True, 'allowedCredentialTypes': ['key-auth'], 'allowedConsumers': ['manager']},
            'upstreams': [{'provider': provider_name, 'weight': 100, 'modelMapping': {}}]
        }
        
        route_result, route_err = higress_api('PUT', '/v1/ai/routes/' + route_name, new_route)
        print('[DEBUG] create_provider: PUT route result: err=' + str(route_err) + ', result=' + str(route_result)[:200] if route_result else 'None')
        
        self.send_json({'success': True, 'provider': provider_name, 'routeName': route_name, 'routeUpdated': True})
    
    def test_provider(self, data):
        provider_name = data.get('provider')
        if not provider_name:
            self.send_json({'success': False, 'error': 'Provider name required'}, 400)
            return
        
        providers_data, err = higress_api('GET', '/v1/ai/providers')
        if err:
            self.send_json({'success': False, 'error': 'Failed to get providers: ' + err}, 500)
            return
        
        providers = providers_data.get('data', providers_data) if providers_data else []
        provider = None
        for p in providers:
            if p.get('name') == provider_name:
                provider = p
                break
        
        if not provider:
            self.send_json({'success': False, 'error': 'Provider not found'}, 404)
            return
        
        tokens = provider.get('tokens', [])
        if not tokens:
            self.send_json({'success': False, 'error': 'No API key configured'}, 400)
            return
        
        api_key = tokens[0] if isinstance(tokens[0], str) else (tokens[0].get('value', '') if isinstance(tokens[0], dict) else '')
        
        raw_configs = provider.get('rawConfigs', {}) or {}
        is_custom = raw_configs.get('_custom') or raw_configs.get('openaiCustomUrl')
        
        if is_custom:
            base_url = raw_configs.get('openaiCustomUrl', '')
            if not base_url:
                base_url = 'https://' + provider_name + '.dns:443/v1'
        else:
            base_url = 'http://ai-gateway.hiclaw.io:8080/' + provider_name + '/v1'
        
        test_url = base_url.rstrip('/') + '/models'
        
        cmd = 'curl -s -m 10 -H "Authorization: Bearer ' + api_key + '" "' + test_url + '"'
        print('[DEBUG] test_provider: testing URL=' + test_url)
        result, err = run_cmd(cmd)
        
        if err:
            self.send_json({'success': False, 'error': 'Connection failed: ' + err}, 500)
            return
        
        if not result:
            self.send_json({'success': False, 'error': 'Empty response from provider'}, 500)
            return
        
        print('[DEBUG] test_provider: response=' + str(result)[:200])
        
        try:
            response = json.loads(result)
            if 'error' in response:
                self.send_json({'success': False, 'error': response.get('error', {}).get('message', 'API error')}, 500)
            elif 'data' in response or 'models' in response:
                self.send_json({'success': True, 'models': len(response.get('data', response.get('models', [])))})
            else:
                self.send_json({'success': True, 'response': 'connected'})
        except:
            if '200' in result or 'OK' in result or result:
                self.send_json({'success': True, 'response': 'connected'})
            else:
                self.send_json({'success': False, 'error': 'Invalid response'}, 500)
    
    def manage_ai_routes(self, provider, model):
        """
        Manage AI routes with dedicated route per provider:
        - Each provider gets its own route (e.g., qwen-ai-route, alibaba-ai-route)
        - Routes use modelPredicates to distinguish traffic
        - No default-ai-route modification
        
        Returns: (success, error_message)
        """
        print('[DEBUG] Managing AI routes for provider: ' + provider + ', model: ' + model)
        
        # Get all existing AI routes
        routes_resp, err = higress_api('GET', '/v1/ai/routes')
        if err or not routes_resp:
            return False, 'Failed to get AI routes: ' + str(err)
        
        # Parse routes from response wrapper
        routes_data = routes_resp.get('data', routes_resp) if isinstance(routes_resp, dict) else []
        if isinstance(routes_data, dict) and 'items' in routes_data:
            routes_list = routes_data['items']
        elif isinstance(routes_data, list):
            routes_list = routes_data
        else:
            routes_list = [routes_data] if routes_data else []
        
        # Filter AI routes (exclude MCP routes and default-ai-route)
        ai_routes = [r for r in routes_list if r.get('name', '').endswith('-ai-route') and r.get('name') != 'default-ai-route']
        
        print('[DEBUG] Found ' + str(len(ai_routes)) + ' provider-specific AI route(s)')
        for r in ai_routes:
            print('[DEBUG]   - Route: ' + r.get('name') + ', provider: ' + str(r.get('upstreams', [{}])[0].get('provider')))
        
        # Check if this provider already has a route
        for route in ai_routes:
            if route.get('upstreams', [{}])[0].get('provider') == provider:
                print('[DEBUG] Route for provider ' + provider + ' already exists: ' + route.get('name'))
                return True, None  # Route exists, no action needed
        
        # Always create a dedicated route for each provider
        print('[DEBUG] No existing route for provider: ' + provider + ', creating new route...')
        result = self.create_provider_route(provider, model)
        print('[DEBUG] Route creation result: ' + str(result))
        return result
    
    def update_default_route(self, provider):
        """Update default-ai-route to use the specified provider"""
        route_name = 'default-ai-route'
        
        print('[DEBUG] Updating default AI route to use provider: ' + provider)
        
        current_route, err = higress_api('GET', '/v1/ai/routes/' + route_name)
        if err or not current_route:
            # Create new default route if it doesn't exist
            print('[DEBUG] Default route not found, creating...')
            return self.create_default_route(provider)
        
        route_data = current_route.get('data', current_route)
        if not route_data:
            return False, 'Invalid route response'
        
        # Remove modelPredicates to make it catch-all
        if 'modelPredicates' in route_data:
            del route_data['modelPredicates']
        
        # Update provider in upstreams[0]
        if 'upstreams' in route_data and len(route_data['upstreams']) > 0:
            route_data['upstreams'][0]['provider'] = provider
        else:
            route_data['upstreams'] = [{'provider': provider, 'weight': 100, 'modelMapping': {}}]
        
        # Ensure headerControl is set
        if 'headerControl' not in route_data:
            route_data['headerControl'] = {
                'enabled': True,
                'request': {'add': [], 'set': [], 'remove': []},
                'response': {'add': [], 'set': [], 'remove': []}
            }
        
        result, err = higress_api('PUT', '/v1/ai/routes/' + route_name, route_data)
        if err:
            return False, 'Failed to update default route: ' + str(err)
        
        print('[DEBUG] Default route updated successfully')
        return True, None
    
    def create_default_route(self, provider):
        """Create default-ai-route"""
        ai_gateway_domain = os.environ.get('HICLAW_AI_GATEWAY_DOMAIN', 'aigw-local.hiclaw.io')
        hiclaw_version = os.environ.get('HICLAW_VERSION', 'latest')
        
        route_body = {
            'name': 'default-ai-route',
            'domains': [ai_gateway_domain],
            'pathPredicate': {'matchType': 'PRE', 'matchValue': '/', 'caseSensitive': False},
            'upstreams': [{'provider': provider, 'weight': 100, 'modelMapping': {}}],
            'authConfig': {
                'enabled': True,
                'allowedCredentialTypes': ['key-auth'],
                'allowedConsumers': ['manager']
            },
            'headerControl': {
                'enabled': True,
                'request': {
                    'add': [{'key': 'user-agent', 'value': 'HiClaw/' + hiclaw_version}],
                    'set': [],
                    'remove': []
                },
                'response': {'add': [], 'set': [], 'remove': []}
            }
        }
        
        result, err = higress_api('POST', '/v1/ai/routes', route_body)
        if err:
            return False, 'Failed to create default route: ' + str(err)
        
        print('[DEBUG] Default route created successfully')
        return True, None
    
    def create_provider_route(self, provider, model):
        """Create a new AI route for a specific provider
        
        IMPORTANT: Higress uses path-based routing, not modelPredicates.
        The route matches all paths and forwards to the provider.
        OpenClaw constructs URLs like: /{provider}/v1/chat/completions
        Higress will route based on the path prefix.
        """
        ai_gateway_domain = os.environ.get('HICLAW_AI_GATEWAY_DOMAIN', 'aigw-local.hiclaw.io')
        hiclaw_version = os.environ.get('HICLAW_VERSION', 'latest')
        
        route_name = provider + '-ai-route'
        
        print('[DEBUG] Creating provider route: ' + route_name)
        print('[DEBUG]   Domain: ' + ai_gateway_domain)
        print('[DEBUG]   Provider: ' + provider)
        
        # Route configuration:
        # - pathPredicate: / (matches all paths)
        # - No modelPredicates (we use path-based routing)
        # - OpenClaw will call: POST /{provider}/v1/chat/completions
        # - Higress will forward to the provider based on path
        route_body = {
            'name': route_name,
            'domains': [ai_gateway_domain],
            'pathPredicate': {'matchType': 'PRE', 'matchValue': '/', 'caseSensitive': False},
            'upstreams': [{'provider': provider, 'weight': 100, 'modelMapping': {}}],
            # NO modelPredicates - we use path-based routing
            'authConfig': {
                'enabled': True,
                'allowedCredentialTypes': ['key-auth'],
                'allowedConsumers': ['manager']
            },
            'headerControl': {
                'enabled': True,
                'request': {
                    'add': [{'key': 'user-agent', 'value': 'HiClaw/' + hiclaw_version}],
                    'set': [],
                    'remove': []
                },
                'response': {'add': [], 'set': [], 'remove': []}
            }
        }
        
        print('[DEBUG] Sending POST /v1/ai/routes with body: ' + json.dumps(route_body, indent=2)[:500])
        
        result, err = higress_api('POST', '/v1/ai/routes', route_body)
        if err:
            print('[ERROR] Failed to create provider route: ' + err)
            return False, 'Failed to create provider route: ' + str(err)
        
        print('[DEBUG] Provider route created successfully: ' + route_name)
        print('[DEBUG] Route creation result: ' + str(result)[:200])
        return True, None
    
    def set_model(self, data):
        target = data.get('target', 'manager')
        provider = data.get('provider')
        model = data.get('model')
        context_window = data.get('contextWindow', 200000)
        max_tokens = data.get('maxTokens', 64000)
        reasoning = data.get('reasoning', True)
        
        if not provider or not model:
            self.send_json({'success': False, 'error': 'Provider and model are required'}, 400)
            return
        
        errors = []
        route_updated = False
        
        if target == 'manager':
            # Manage AI routes FIRST (before testing connectivity)
            # This ensures the route exists for the connectivity test
            print('[DEBUG] Managing AI routes before testing connectivity...')
            route_success, route_error = self.manage_ai_routes(provider, model)
            if not route_success:
                errors.append(route_error)
            else:
                route_updated = True
                print('[DEBUG] AI routes managed successfully')
            
            # Test model connectivity after route is set up
            print('[DEBUG] Testing model connectivity...')
            test_result = self.test_model_connectivity(provider, model)
            if not test_result.get('success', False):
                self.send_json({
                    'success': False, 
                    'error': 'Model not reachable: ' + str(test_result.get('error', 'Unknown error')),
                    'hint': 'Check if the Provider is correctly configured in Higress Console'
                })
                return
            
            # Update OpenClaw config using the standard format
            if os.path.exists(OPENCLAW_CONFIG):
                try:
                    with open(OPENCLAW_CONFIG) as f:
                        config = json.load(f)
                    
                    # Use standard hiclaw-gateway provider format
                    gateway_provider_name = 'hiclaw-gateway'
                    
                    # Use configured AI Gateway domain
                    # IMPORTANT: Model ID must include provider prefix for Higress routing
                    # Format: {provider}/{model-name} (e.g., "ark/doubao-pro-32k")
                    # baseUrl: http://{domain}:8080
                    # OpenClaw will construct: POST /{provider}/v1/chat/completions
                    # Example: POST /ark/v1/chat/completions
                    ai_gateway_domain = os.environ.get('HICLAW_AI_GATEWAY_DOMAIN', 'aigw-local.hiclaw.io')
                    gateway_base_url = 'http://' + ai_gateway_domain + ':8080'
                    
                    # Ensure models.providers structure exists
                    if 'models' not in config:
                        config['models'] = {'mode': 'merge', 'providers': {}}
                    if 'providers' not in config['models']:
                        config['models']['providers'] = {}
                    if gateway_provider_name not in config['models']['providers']:
                        config['models']['providers'][gateway_provider_name] = {
                            'baseUrl': gateway_base_url,
                            'apiKey': os.environ.get('MANAGER_GATEWAY_KEY') or os.environ.get('HICLAW_MANAGER_GATEWAY_KEY', ''),
                            'api': 'openai-completions',
                            'models': []
                        }
                    
                    models_list = config['models']['providers'][gateway_provider_name].get('models', [])
                    
                    # IMPORTANT: Model ID must include provider prefix for Higress routing
                    # Format: {provider}/{model-name} (e.g., "ark/doubao-pro-32k")
                    # This allows OpenClaw to construct correct URL: POST /{provider}/v1/chat/completions
                    full_model_id = provider + '/' + model
                    model_exists = any(m.get('id') == full_model_id for m in models_list)
                    
                    if not model_exists:
                        # Add new model to the list with provider prefix
                        models_list.append({
                            'id': full_model_id,
                            'name': model,
                            'reasoning': reasoning,
                            'contextWindow': context_window,
                            'maxTokens': max_tokens,
                            'input': ['text', 'image'] if reasoning else ['text']
                        })
                        config['models']['providers'][gateway_provider_name]['models'] = models_list
                        print('[DEBUG] Added new model to openclaw.json: ' + full_model_id)
                        print('[DEBUG]   baseUrl: ' + gateway_base_url)
                    
                    # Set as primary model (with provider prefix)
                    model_id = gateway_provider_name + '/' + full_model_id
                    
                    if 'agents' not in config:
                        config['agents'] = {'defaults': {}}
                    if 'defaults' not in config['agents']:
                        config['agents']['defaults'] = {}
                    if 'model' not in config['agents']['defaults']:
                        config['agents']['defaults']['model'] = {}
                    
                    config['agents']['defaults']['model']['primary'] = model_id
                    
                    # Add to agents.defaults.models alias map
                    if 'models' not in config['agents']['defaults']:
                        config['agents']['defaults']['models'] = {}
                    config['agents']['defaults']['models'][model_id] = {'alias': model}
                    
                    with open(OPENCLAW_CONFIG, 'w') as f:
                        json.dump(config, f, indent=2)
                    
                    # Trigger OpenClaw reload
                    subprocess.run(['curl', '-s', '-X', 'POST', 'http://127.0.0.1:18799/api/reload'], check=False, timeout=5)
                    print('[DEBUG] OpenClaw config reloaded')
                    
                except Exception as e:
                    errors.append('Failed to update OpenClaw config: ' + str(e))
            else:
                errors.append('OpenClaw config not found: ' + OPENCLAW_CONFIG)
            
            # Store model assignment for persistence
            model_dir = os.path.join(AGENTS_DIR, 'manager')
            os.makedirs(model_dir, exist_ok=True)
            with open(os.path.join(model_dir, 'model.json'), 'w') as f:
                json.dump({
                    'provider': provider,
                    'model': model,
                    'contextWindow': context_window,
                    'maxTokens': max_tokens,
                    'reasoning': reasoning,
                    'updatedAt': datetime.utcnow().isoformat() + 'Z'
                }, f, indent=2)
        else:
            # Worker model assignment
            worker_dir = os.path.join(AGENTS_DIR, target)
            os.makedirs(worker_dir, exist_ok=True)
            
            # Store in model.json
            with open(os.path.join(worker_dir, 'model.json'), 'w') as f:
                json.dump({
                    'provider': provider,
                    'model': model,
                    'contextWindow': context_window,
                    'maxTokens': max_tokens,
                    'reasoning': reasoning,
                    'updatedAt': datetime.utcnow().isoformat() + 'Z'
                }, f, indent=2)
            
            # Update Worker's openclaw.json in MinIO
            worker_openclaw = os.path.join(worker_dir, 'openclaw.json')
            if os.path.exists(worker_openclaw):
                try:
                    with open(worker_openclaw) as f:
                        config = json.load(f)
                    
                    gateway_provider_name = 'hiclaw-gateway'
                    
                    if 'models' not in config:
                        config['models'] = {'mode': 'merge', 'providers': {}}
                    if 'providers' not in config['models']:
                        config['models']['providers'] = {}
                    if gateway_provider_name not in config['models']['providers']:
                        config['models']['providers'][gateway_provider_name] = {
                            'baseUrl': 'http://ai-gateway.hiclaw.io:8080/v1',
                            'apiKey': '',
                            'api': 'openai-completions',
                            'models': []
                        }
                    
                    models_list = config['models']['providers'][gateway_provider_name].get('models', [])
                    model_exists = any(m.get('id') == model for m in models_list)
                    
                    if not model_exists:
                        models_list.append({
                            'id': model,
                            'name': model,
                            'reasoning': reasoning,
                            'contextWindow': context_window,
                            'maxTokens': max_tokens,
                            'input': ['text']
                        })
                        config['models']['providers'][gateway_provider_name]['models'] = models_list
                    
                    model_id = gateway_provider_name + '/' + model
                    if 'agents' not in config:
                        config['agents'] = {'defaults': {}}
                    if 'defaults' not in config['agents']:
                        config['agents']['defaults'] = {}
                    if 'models' not in config['agents']['defaults']:
                        config['agents']['defaults']['models'] = {}
                    
                    config['agents']['defaults']['models'][model_id] = {'alias': model}
                    
                    with open(worker_openclaw, 'w') as f:
                        json.dump(config, f, indent=2)
                    
                    # Sync to MinIO
                    subprocess.run(['mc', 'cp', worker_openclaw, HICLAW_FS + '/agents/' + target + '/openclaw.json'], 
                                 check=False, capture_output=True)
                    print('[DEBUG] Worker openclaw.json synced to MinIO')
                    
                except Exception as e:
                    errors.append('Failed to update Worker config: ' + str(e))
        
        if errors:
            self.send_json({'success': False, 'errors': errors})
        else:
            self.send_json({
                'success': True, 
                'target': target, 
                'provider': provider, 
                'model': model,
                'routeUpdated': route_updated
            })
    
    def test_model_connectivity(self, provider, model):
        """Test if a model is reachable via the AI Gateway"""
        # Use the configured AI Gateway domain (default: aigw-local.hiclaw.io)
        ai_gateway_domain = os.environ.get('HICLAW_AI_GATEWAY_DOMAIN', 'aigw-local.hiclaw.io')
        
        # IMPORTANT: URL must include Provider path!
        # Format: http://{domain}:8080/{provider}/v1/chat/completions
        # Example: http://aigw-local.hiclaw.io:8080/ark/v1/chat/completions
        test_url = 'http://' + ai_gateway_domain + ':8080/' + provider + '/v1/chat/completions'
        
        # Use Manager consumer's gateway key for authentication
        # The AI Gateway route requires key-auth with consumer 'manager'
        gateway_key = os.environ.get('MANAGER_GATEWAY_KEY') or os.environ.get('HICLAW_MANAGER_GATEWAY_KEY', '')
        
        print('[DEBUG] Testing model connectivity via AI Gateway:')
        print('[DEBUG]   Provider: ' + provider)
        print('[DEBUG]   Model: ' + model)
        print('[DEBUG]   URL: ' + test_url)
        print('[DEBUG]   Domain: ' + ai_gateway_domain)
        
        if not gateway_key:
            print('[WARNING] Gateway key not available, skipping connectivity test')
            print('[HINT] This is OK if routes were created successfully')
            return {'success': True, 'note': 'Gateway key not available, assuming connectivity'}
        
        print('[DEBUG]   Auth: Manager Gateway Key (Bearer Token)')
        
        test_body = {
            'model': model,
            'messages': [{'role': 'user', 'content': 'Hello'}],
            'max_tokens': 1
        }
        
        cmd = 'curl -s -m 10 -X POST "' + test_url + '" -H "Content-Type: application/json" -H "Authorization: Bearer ' + gateway_key + '" -d \'' + json.dumps(test_body) + '\''
        print('[DEBUG] curl command: ' + cmd[:300])
        result, err = run_cmd(cmd)
        
        print('[DEBUG] curl result:')
        if result:
            print('[DEBUG]   Response: ' + result[:200])
        else:
            print('[DEBUG]   Response: (empty)')
        if err:
            print('[DEBUG]   Error: ' + str(err))
        
        if err:
            return {'success': False, 'error': 'Connection failed: ' + str(err)}
        
        if not result:
            # Try to get more info about why it failed
            # Check if the domain resolves
            resolve_check, _ = run_cmd('curl -s -m 5 -I "http://' + ai_gateway_domain + ':8080/" 2>&1 | head -n1')
            print('[DEBUG] Domain check: ' + str(resolve_check))
            return {'success': False, 'error': 'Empty response. Domain check: ' + str(resolve_check)}
        
        try:
            response = json.loads(result)
            if 'error' in response:
                return {'success': False, 'error': response['error'].get('message', 'API error')}
            return {'success': True, 'response': response}
        except:
            if '200' in result or 'choices' in result:
                return {'success': True}
            return {'success': False, 'error': 'Invalid response: ' + result[:100]}
            
            worker_config = os.path.join(HICLAW_FS, 'agents', target, 'openclaw.json')
            if os.path.exists(worker_config):
                try:
                    with open(worker_config) as f:
                        config = json.load(f)
                    
                    model_id = 'hiclaw-gateway/' + model
                    
                    if 'models' in config and 'providers' in config['models']:
                        if 'hiclaw-gateway' in config['models']['providers']:
                            models_list = config['models']['providers']['hiclaw-gateway'].get('models', [])
                            model_exists = any(m.get('id') == model for m in models_list)
                            
                            if not model_exists:
                                models_list.append({
                                    'id': model,
                                    'name': model,
                                    'reasoning': reasoning,
                                    'contextWindow': context_window,
                                    'maxTokens': max_tokens,
                                    'input': ['text']
                                })
                            
                            if 'agents' in config and 'defaults' in config['agents']:
                                if 'model' in config['agents']['defaults']:
                                    config['agents']['defaults']['model']['primary'] = model_id
                                if 'models' not in config['agents']['defaults']:
                                    config['agents']['defaults']['models'] = {}
                                config['agents']['defaults']['models'][model_id] = {'alias': model}
                    
                    with open(worker_config, 'w') as f:
                        json.dump(config, f, indent=2)
                    
                except Exception as e:
                    errors.append('Failed to update worker config: ' + str(e))
        
        if errors:
            self.send_json({'success': False, 'errors': errors, 'partial': True})
        else:
            self.send_json({
                'success': True,
                'target': target,
                'provider': provider,
                'model': model,
                'routeUpdated': route_updated
            })

class ReuseAddrServer(socketserver.TCPServer):
    allow_reuse_address = True

with ReuseAddrServer(('', PORT), MonitorHandler) as httpd:
    print('Monitor server running on port ' + str(PORT))
    httpd.serve_forever()
EOF

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
