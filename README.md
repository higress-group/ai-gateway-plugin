# AI Gateway Management

A skill plugin for HiClaw Manager that provides a web-based management interface for the AI Gateway.

## Features

- **Provider Management** — Add, remove, and configure LLM providers (Qwen, DeepSeek, OpenAI, etc.)
- **Model Assignment** — Set default models for Manager and individual Workers
- **Dynamic Switching** — Change models at runtime with automatic connectivity testing
- **Pixel Art UI** — Retro-style web interface with theme switching
- **Backup & Restore** — Automatic backups before configuration changes

## Installation

### As a HiClaw Skill

Copy this directory to your HiClaw Manager's skills directory:

```bash
cp -r ai-gateway-management /opt/hiclaw/agent/skills/
```

The skill will auto-start on Manager restart.

### Manual Installation

1. Clone this repository
2. Copy the contents to `manager/agent/skills/ai-gateway-management/` in your HiClaw installation
3. Rebuild the Manager container

## Usage

### Web UI

The management interface is accessible via multiple ways:

#### 1. Domain-based Access (Default)
```
http://manager-local.hiclaw.io:8080
```

#### 2. Path-based Access (LAN/Internet)
```
http://<your-server-ip>:8080/agm/
```

This allows access from LAN or internet without configuring a domain.

**Default credentials:**
- Username: `admin` (or `HICLAW_ADMIN_USER` env var)
- Password: Set during installation (or `HICLAW_ADMIN_PASSWORD` env var)

### CLI Scripts

```bash
# List all providers
bash scripts/list-providers.sh

# Create a new provider
bash scripts/create-provider.sh --type qwen --name qwen --token "sk-xxx"

# Set Manager model (with connectivity test)
bash scripts/set-model.sh --target manager --provider qwen --model qwen3.5-plus

# Set Worker model
bash scripts/set-model.sh --target worker:alice --provider deepseek --model deepseek-chat

# Get current assignment
bash scripts/get-assignment.sh manager
bash scripts/get-assignment.sh worker:alice

# Monitor server management
bash scripts/monitor-server.sh start
bash scripts/monitor-server.sh stop
bash scripts/monitor-server.sh status
```

## Directory Structure

```
ai-gateway-management/
├── SKILL.md              # Skill documentation (read by Agent)
├── README.md             # This file (developer documentation)
├── scripts/              # CLI scripts
│   ├── monitor-server.sh     # Python HTTP server for API
│   ├── list-providers.sh     # List AI providers
│   ├── create-provider.sh    # Create new provider
│   ├── set-model.sh          # Set model (with testing)
│   └── get-assignment.sh     # Get current model assignment
├── references/           # Reference documentation
│   └── api-reference.md  # API specification
└── web/                  # Web UI
    └── index.html        # Single-page application
```

## Requirements

- HiClaw Manager container
- Higress AI Gateway
- Higress Console (for provider management)
- MinIO (for config storage)
- mc (MinIO client)

## Architecture

### Components

1. **Monitor Server** (`monitor-server.sh`)
   - Python HTTP server on port 18080
   - Provides REST API for model management
   - Handles Higress Console authentication
   - Tests model connectivity before applying changes

2. **Web UI** (`web/index.html`)
   - Single-page application (vanilla JS)
   - Pixel art theme with animations
   - Calls monitor server API
   - Stores backups in browser localStorage

3. **CLI Scripts**
   - `set-model.sh`: Bash wrapper for model switching
   - `list-providers.sh`: Query Higress Console
   - `create-provider.sh`: Create new AI provider
   - `get-assignment.sh`: Read model assignments

### Data Flow

```
Human Admin → Web UI / CLI → Monitor Server → Higress Console API
                                    ↓
                            MinIO (config storage)
                                    ↓
                            OpenClaw Config Reload
```

### Model Assignment Storage

- **Manager**: `/agents/manager/model.json` + `/root/manager-workspace/openclaw.json`
- **Worker**: `/agents/{worker-name}/model.json` + MinIO sync

Format:
```json
{
  "provider": "qwen",
  "model": "qwen3.5-plus",
  "contextWindow": 200000,
  "maxTokens": 64000,
  "reasoning": true,
  "updatedAt": "2024-01-15T10:30:00Z"
}
```

## API Reference

### Monitor API Endpoints

All endpoints require authentication and are prefixed with `/ni_status/`.

#### GET `/ni_status/metrics`

Get system metrics.

Response:
```json
{
  "cpu": 45,
  "memory": 62,
  "connections": 12,
  "rpm": 150,
  "timestamp": "2024-01-15T10:30:00Z"
}
```

#### PUT `/ni_status/assignment/manager`

Set Manager's model.

Request:
```json
{
  "provider": "qwen",
  "model": "qwen3.5-plus",
  "contextWindow": 200000,
  "maxTokens": 64000,
  "reasoning": true
}
```

Response:
```json
{
  "success": true,
  "target": "manager",
  "provider": "qwen",
  "model": "qwen3.5-plus",
  "routeUpdated": true
}
```

#### PUT `/ni_status/assignment/workers/{name}`

Set Worker's model.

Request: Same as Manager
Response: Similar structure

#### POST `/ni_status/test-provider`

Test provider connectivity.

Request:
```json
{
  "provider": "qwen",
  "model": "qwen3.5-plus"
}
```

Response:
```json
{
  "success": true,
  "models": 150
}
```

## How It Works

### Hybrid Routing Mode

The system uses **hybrid routing** to support both single-provider and multi-provider scenarios:

**Single Provider Mode** (default):
- Only one route exists: `default-ai-route`
- All model requests go through this route
- Switching providers updates `default-ai-route` upstream

**Multi-Provider Mode** (automatic):
- When you add a second provider, the system creates separate routes
- Each route has `modelPredicates` to auto-route by model prefix
- Example:
  - `qwen-ai-route` with `modelPredicates: [{matchType: "PRE", matchValue: "qwen"}]`
  - `minimax-ai-route` with `modelPredicates: [{matchType: "PRE", matchValue: "minimax"}]`
  - `default-ai-route` remains as catch-all for unmatched models

**How it works in practice**:
1. First provider → uses `default-ai-route`
2. Second provider added → creates `{provider}-ai-route` with model predicates
3. Third+ provider → creates additional `{provider}-ai-route`
4. Manager/Worker just specify model ID → Higress auto-routes to correct provider

### Manager Model Switching Flow

1. **Connectivity Test**
   - Query Higress Console for provider API key
   - Send test request to `POST /v1/chat/completions`
   - Verify response (must be HTTP 200 with choices)

2. **Manage Routes**
   - Check existing AI routes
   - If only `default-ai-route` exists → update it
   - If multiple routes exist → create new `{provider}-ai-route` with `modelPredicates`

3. **Update OpenClaw Config**
   - Add model to `models.providers["hiclaw-gateway"].models[]` (if new)
   - Set `agents.defaults.model.primary` to `hiclaw-gateway/{model}`
   - Add alias to `agents.defaults.models[{model_id}]`

4. **Reload**
   - POST to `http://127.0.0.1:18799/api/reload`
   - OpenClaw reloads config without restart

### Worker Model Switching Flow

1. **Store Assignment**
   - Write to `/agents/{worker-name}/model.json`

2. **Update Config** (if Worker exists)
   - Update `/agents/{worker-name}/openclaw.json`
   - Sync to MinIO via `mc cp`

3. **Apply on Next Task**
   - Worker pulls config from MinIO on startup/task
   - New model takes effect immediately

## Troubleshooting

### Model Not Reachable

**Symptom**: `set-model.sh` fails with "Model not reachable"

**Causes**:
- Provider doesn't exist in Higress Console
- API key is invalid or expired
- Model name is incorrect
- Network connectivity issue

**Solution**:
1. Open Higress Console → AI Providers
2. Verify provider exists and has valid API key
3. Test manually: `curl -H "Authorization: Bearer <key>" http://ai-gateway.hiclaw.io:8080/v1/models`
4. Check monitor logs: `tail -f /tmp/monitor-server.log`

### OpenClaw Reload Fails

**Symptom**: Model set but Manager doesn't use it

**Solution**:
1. Verify OpenClaw is running: `ps aux | grep openclaw`
2. Manual reload: `curl -X POST http://127.0.0.1:18799/api/reload`
3. Check config: `jq '.agents.defaults.model.primary' /root/manager-workspace/openclaw.json`
4. Restart Manager container if needed

### Worker Model Not Applied

**Symptom**: Worker model set but uses old model

**Solution**:
1. Verify MinIO sync: `mc stat <bucket>/agents/<worker>/openclaw.json`
2. Check Worker logs for config pull errors
3. Restart Worker container
4. Ensure Worker has correct Higress consumer permissions

### Web UI Not Loading

**Symptom**: Blank page or 404

**Solution**:
1. Verify Higress Manager UI route exists
2. Check basic-auth is enabled for the route
3. Clear browser cache and localStorage
4. Check monitor server is running: `bash scripts/monitor-server.sh status`

## Development

### Testing Locally

1. Start monitor server:
   ```bash
   export HIGRESS_COOKIE_FILE=/tmp/higress-cookie.txt
   export HICLAW_ADMIN_USER=admin
   export HICLAW_ADMIN_PASSWORD=admin
   bash scripts/monitor-server.sh start
   ```

2. Test API:
   ```bash
   curl http://localhost:18080/ni_status/health
   curl http://localhost:18080/ni_status/providers
   ```

3. Open web UI in browser: `http://localhost:18080`

### Adding New Features

1. Update `monitor-server.sh` Python code for new API endpoints
2. Update `web/index.html` for UI changes
3. Update `SKILL.md` and `README.md` documentation
4. Test with `set-model.sh` and manual API calls

## License

MIT License

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and test thoroughly
4. Submit a pull request

## Support

For issues or questions:
- Check troubleshooting section above
- Review monitor logs: `/tmp/monitor-server.log`
- Consult HiClaw documentation: `docs/` directory
