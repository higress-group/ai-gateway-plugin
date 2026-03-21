# AI Gateway Management API Reference

This document describes the API endpoints for managing AI Gateway providers and model assignments.

## Authentication

All API endpoints require Basic Authentication. Use the admin credentials configured during installation.

```
Authorization: Basic <base64(admin:password)>
```

## Base URL

```
http://aigw-local.hiclaw.io:8080/_admin/api
```

## Endpoints

### Providers

#### List Providers

```
GET /providers
```

Response:
```json
{
  "success": true,
  "data": [
    {
      "name": "qwen",
      "type": "qwen",
      "tokens": ["sk-xxx"],
      "protocol": "openai/v1"
    }
  ]
}
```

#### Create Provider

```
POST /providers
```

Request Body:
```json
{
  "type": "qwen",
  "name": "qwen",
  "tokens": ["sk-xxx"],
  "protocol": "openai/v1",
  "rawConfigs": {
    "qwenEnableSearch": false,
    "qwenEnableCompatible": true,
    "mergeConsecutiveMessages": true
  }
}
```

#### Get Provider

```
GET /providers/{name}
```

#### Update Provider

```
PUT /providers/{name}
```

#### Delete Provider

```
DELETE /providers/{name}
```

### Model Assignment

#### Get All Assignments

```
GET /assignment
```

Response:
```json
{
  "manager": {
    "provider": "qwen",
    "model": "qwen3.5-plus",
    "contextWindow": 200000
  },
  "workers": {
    "alice": {
      "provider": "deepseek",
      "model": "deepseek-chat",
      "contextWindow": 256000
    }
  }
}
```

#### Get Manager Assignment

```
GET /assignment/manager
```

Response:
```json
{
  "provider": "qwen",
  "model": "qwen3.5-plus",
  "contextWindow": 200000,
  "reasoning": true,
  "updatedAt": "2024-01-15T10:30:00Z"
}
```

#### Set Manager Model

```
PUT /assignment/manager
```

Request Body:
```json
{
  "provider": "qwen",
  "model": "qwen3.5-plus",
  "contextWindow": 200000,
  "maxTokens": 64000,
  "reasoning": true
}
```

**Note:** Changes to Manager model require a config reload (handled automatically by the script).

#### List Worker Assignments

```
GET /assignment/workers
```

Response:
```json
{
  "alice": {
    "provider": "deepseek",
    "model": "deepseek-chat",
    "contextWindow": 256000
  },
  "bob": {
    "provider": "qwen",
    "model": "qwen3.5-plus",
    "contextWindow": 200000
  }
}
```

#### Get Worker Assignment

```
GET /assignment/workers/{name}
```

#### Set Worker Model

```
PUT /assignment/workers/{name}
```

Request Body:
```json
{
  "provider": "deepseek",
  "model": "deepseek-chat",
  "contextWindow": 256000,
  "maxTokens": 128000,
  "reasoning": false
}
```

**Note:** Changes to Worker model are applied immediately via Matrix notification.

## Error Responses

All endpoints return consistent error responses:

```json
{
  "success": false,
  "message": "Error description",
  "code": "ERROR_CODE"
}
```

Common error codes:
- `PROVIDER_NOT_FOUND`: The specified provider does not exist
- `WORKER_NOT_FOUND`: The specified worker does not exist
- `INVALID_MODEL`: The model ID is invalid or not supported
- `AUTH_FAILED`: Authentication failed
