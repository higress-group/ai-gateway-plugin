---
name: ai-gateway-management
description: Manage AI Gateway providers, routes, and model assignments for Manager and Workers. Provides a web UI and API for dynamic configuration.
---

# AI Gateway Management

This skill provides a web-based management interface for the AI Gateway, allowing human admins to:

1. **Manage AI Providers** — Add, edit, remove LLM providers (Qwen, DeepSeek, OpenAI, etc.)
2. **Assign Models** — Set default models for Manager and individual Workers
3. **Dynamic Switching** — Change models at runtime without container restart
4. **Monitor System** — View system metrics and worker status
5. **Backup & Restore** — Backup configurations and restore when needed

## Web UI Access

The management interface is accessible via multiple ways:

### 1. Manager Domain (Default)
```
http://manager-local.hiclaw.io:8080
```

### 2. Path-based Access (LAN/Internet)
```
http://<your-server-ip>:8080/agm/
```

This allows access from LAN or internet without configuring a domain.

### Authentication
Both access methods require Basic Auth:
- Username: `admin` (or `HICLAW_ADMIN_USER` env var)
- Password: Set during installation (or `HICLAW_ADMIN_PASSWORD` env var)

## Features

### Theme Switching

Three themes available:
- **Pixel** — Classic green terminal style
- **Cyber** — Neon pink/cyan cyberpunk style  
- **Office** — Warm brown retro office style

### Worker Status Animation

Workers display animated pixel-art avatars with status indicators:
- 🟢 **Idle** — Green, ready for tasks
- 🟡 **Busy** — Yellow, currently processing
- 🔵 **Sleeping** — Blue, inactive
- 🔴 **Offline** — Red, not connected

### Backup & Reset

- Automatic backup before any configuration change
- Manual backup button on home page
- Reset button to restore from last backup

## API Endpoints

All endpoints are prefixed with `/ni_status/` and require authentication.

### Monitor API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/ni_status/metrics` | Get system metrics (CPU, memory, connections) |
| POST | `/ni_status/reload` | Reload configuration for Manager or Worker |
| GET | `/ni_status/health` | Health check endpoint |

### Model Assignment API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/ni_status/assignment/manager` | Get Manager's current model |
| PUT | `/ni_status/assignment/manager` | Set Manager's model |
| GET | `/ni_status/assignment/workers` | List all Worker model assignments |
| GET | `/ni_status/assignment/workers/{name}` | Get Worker's model |
| PUT | `/ni_status/assignment/workers/{name}` | Set Worker's model |
| POST | `/ni_status/set-model` | Set model (alternative endpoint) |
| POST | `/ni_status/test-provider` | Test provider connectivity |

### Provider Management API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/ni_status/providers` | List all AI providers |
| POST | `/ni_status/create-provider` | Create a new provider |
| GET | `/ni_status/route` | Get current AI routes |

## Scripts

### `monitor-server.sh`

Starts the monitor API server on port 18080.

```bash
# Start monitor server
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/monitor-server.sh start

# Stop monitor server
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/monitor-server.sh stop

# Check status
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/monitor-server.sh status
```

### `list-providers.sh`

List all configured AI providers.

```bash
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/list-providers.sh
```

### `create-provider.sh`

Create a new AI provider.

```bash
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/create-provider.sh \
  --type qwen \
  --name qwen \
  --token "sk-xxx"
```

### `set-model.sh`

Set model for Manager or a Worker. **Tests connectivity before applying**.

```bash
# Set Manager model
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/set-model.sh \
  --target manager \
  --provider qwen \
  --model qwen3.5-plus

# Set Worker model
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/set-model.sh \
  --target worker:alice \
  --provider deepseek \
  --model deepseek-chat

# With custom parameters
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/set-model.sh \
  --target manager \
  --provider openai \
  --model gpt-4 \
  --context-window 128000 \
  --max-tokens 8192 \
  --reasoning true
```

### `get-assignment.sh`

Get current model assignment.

```bash
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/get-assignment.sh manager
bash /opt/hiclaw/agent/skills/ai-gateway-management/scripts/get-assignment.sh worker:alice
```

## Installation

When this skill is installed, it automatically:

1. Creates a **monitor** service source pointing to `127.0.0.1:18080`
2. Creates a route with prefix `/ni_status` pointing to the monitor service
3. Enables key-auth for the route (manager access only)
4. Starts the monitor API server

## Model Assignment Storage

Model assignments are stored in MinIO for persistence:

- Manager: `/agents/manager/model.json`
- Workers: `/agents/{worker-name}/model.json`

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

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Higress AI Gateway                       │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  Route: /ni_status/* → monitor service (this skill)     ││
│  │  Route: /v1/*         → AI Providers (LLM proxy)        ││
│  │  Route: /           → default-ai-route (configurable)   ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
        ┌──────────┐    ┌──────────┐    ┌──────────┐
        │ Manager  │    │ Worker 1 │    │ Worker N │
        │ (model A)│    │ (model B)│    │ (model C)│
        └──────────┘    └──────────┘    └──────────┘
```

## How It Works

### Manager Model Switching

1. **Connectivity Test**: The skill tests the model via `POST /v1/chat/completions` to ensure it's reachable
2. **Update AI Route**: Updates `default-ai-route` to use the new provider
3. **Update OpenClaw Config**: Modifies `openclaw.json` using the standard `hiclaw-gateway` provider format
4. **Reload**: Triggers OpenClaw config reload via API

### Worker Model Switching

1. **Store Assignment**: Saves model assignment to `/agents/{worker-name}/model.json`
2. **Update Config**: Updates Worker's `openclaw.json` in MinIO
3. **Apply on Next Task**: Worker pulls updated config on next task assignment

## Important Notes

### Prerequisites

Before switching models, ensure:
- The AI Provider exists in Higress Console
- The provider has a valid API key configured
- The model is supported by the provider

### Error Handling

If model switching fails:
1. Check Higress Console for provider configuration
2. Verify the model name is correct
3. Test connectivity manually via curl
4. Check monitor server logs at `/tmp/monitor-server.log`

### Default AI Route

This skill uses the **default-ai-route** for all model requests. Do not create separate routes for each provider unless you need advanced routing (e.g., model-based routing with predicates).

### Backup & Restore

Model assignments are backed up automatically before changes:
- Backup file: `/agents/{name}/model.json.backup.YYYYMMDD_HHMMSS`
- Restore manually by copying backup file back

## Troubleshooting

### Model not reachable

**Symptom**: `set-model.sh` fails with "Model not reachable" error

**Solution**:
1. Open Higress Console
2. Navigate to AI Providers
3. Verify provider exists and has API key
4. Test model manually: `curl -H "Authorization: Bearer <key>" http://ai-gateway.hiclaw.io:8080/v1/models`

### OpenClaw reload fails

**Symptom**: Model set but Manager doesn't use it

**Solution**:
1. Check OpenClaw is running: `ps aux | grep openclaw`
2. Manually reload: `curl -X POST http://127.0.0.1:18799/api/reload`
3. Verify config: `jq '.agents.defaults.model.primary' /root/manager-workspace/openclaw.json`

### Worker model not applied

**Symptom**: Worker model set but Worker uses old model

**Solution**:
1. Verify MinIO sync: `mc stat <bucket>/agents/<worker>/openclaw.json`
2. Restart Worker container
3. Check Worker logs for config pull errors
