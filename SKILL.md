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

The management interface is accessible via the AI Gateway:

```
http://manager-local.hiclaw.io:8080
```

Authentication: Basic Auth (admin credentials set during installation)

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

Set model for Manager or a Worker.

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

## Notes

- Model changes for Manager trigger an immediate config reload
- Model changes for Workers are persisted and applied on next task
- Each Worker can have a different provider and model
- The web UI provides a visual interface for all operations
- Backups are stored in browser localStorage
