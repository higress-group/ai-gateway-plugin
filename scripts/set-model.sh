#!/bin/bash
# set-model.sh - Set model for Manager or Worker with immediate effect
#
# Usage:
#   set-model.sh --target manager --provider qwen --model qwen3.5-plus
#   set-model.sh --target worker:alice --provider deepseek --model deepseek-chat
#
# Options:
#   --target      Target entity: "manager" or "worker:{name}"
#   --provider    Provider name (e.g., qwen, deepseek, openai)
#   --model       Model ID (e.g., qwen3.5-plus, deepseek-chat)
#   --context-window  Context window size (default: 200000)
#   --max-tokens  Max output tokens (default: 64000)
#   --reasoning   Enable reasoning mode (true/false, default: true)

set -e
source /opt/hiclaw/scripts/lib/base.sh

TARGET=""
PROVIDER=""
MODEL=""
CONTEXT_WINDOW=200000
MAX_TOKENS=64000
REASONING=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --target) TARGET="$2"; shift 2 ;;
        --provider) PROVIDER="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --context-window) CONTEXT_WINDOW="$2"; shift 2 ;;
        --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
        --reasoning) REASONING="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "${TARGET}" ] || [ -z "${PROVIDER}" ] || [ -z "${MODEL}" ]; then
    echo "Usage: $0 --target <manager|worker:name> --provider <name> --model <id> [--context-window N] [--max-tokens N] [--reasoning true|false]"
    exit 1
fi

ENTITY_TYPE="manager"
ENTITY_NAME="manager"

if [[ "${TARGET}" == worker:* ]]; then
    ENTITY_TYPE="worker"
    ENTITY_NAME="${TARGET#worker:}"
fi

log "Setting model for ${ENTITY_TYPE}: ${ENTITY_NAME}"
log "  Provider: ${PROVIDER}"
log "  Model: ${MODEL}"
log "  Context Window: ${CONTEXT_WINDOW}"
log "  Max Tokens: ${MAX_TOKENS}"
log "  Reasoning: ${REASONING}"

# Test model connectivity first (Manager only)
if [ "${ENTITY_TYPE}" = "manager" ]; then
    log "Testing model connectivity..."
    
    CONSOLE_URL="http://127.0.0.1:8001"
    HIGRESS_COOKIE_FILE="${HIGRESS_COOKIE_FILE:-/tmp/higress-session-cookie}"
    
    # Get API key from provider
    provider_resp=$(curl -s -X GET "${CONSOLE_URL}/v1/ai/providers" \
        -b "${HIGRESS_COOKIE_FILE}" 2>/dev/null)
    
    api_key=$(echo "${provider_resp}" | jq -r --arg provider "${PROVIDER}" '
        (.data[]? // .[]?) | select(.name == $provider) | 
        (.tokens[0] // "") | if type == "string" then . else (.value // "") end
    ' 2>/dev/null)
    
    if [ -z "${api_key}" ]; then
        log "ERROR: Provider '${PROVIDER}' not found or has no API key configured"
        log "Ask admin to create the provider in Higress Console first"
        exit 1
    fi
    
    # Test the model
    test_resp=$(curl -s -X POST "http://ai-gateway.hiclaw.io:8080/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${api_key}" \
        -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":1}" \
        2>/dev/null)
    
    if echo "${test_resp}" | grep -q '"error"'; then
        error_msg=$(echo "${test_resp}" | jq -r '.error.message // "Unknown error"' 2>/dev/null)
        log "ERROR: Model test failed: ${error_msg}"
        log ""
        log "To fix this, admin needs to:"
        log "  1. Open Higress Console"
        log "  2. Create AI Provider for '${PROVIDER}' (if not exists)"
        log "  3. Ensure the provider supports model '${MODEL}'"
        log "  4. Try again"
        exit 1
    fi
    
    log "Model connectivity test passed"
    
    # Manage AI routes with hybrid mode
    log "Managing AI routes (hybrid mode)..."
    
    # Get all existing AI routes
    routes_resp=$(curl -s -X GET "${CONSOLE_URL}/v1/ai/routes" \
        -b "${HIGRESS_COOKIE_FILE}" 2>/dev/null)
    
    # Parse routes from response
    ai_routes=$(echo "${routes_resp}" | jq -r '
        (.data.items // .data // []) | 
        if type == "array" then . else [] end |
        map(select(.name | endswith("-ai-route")))
    ' 2>/dev/null)
    
    route_count=$(echo "${ai_routes}" | jq 'length' 2>/dev/null)
    log "Found ${route_count} AI route(s)"
    
    # Check if provider already has a route
    existing_route=$(echo "${ai_routes}" | jq -r --arg provider "${PROVIDER}" '
        .[] | select(.upstreams[0].provider == $provider) | .name
    ' 2>/dev/null | head -n1)
    
    if [ -n "${existing_route}" ]; then
        log "Provider '${PROVIDER}' already has route: ${existing_route}"
        log "Skipping route creation"
    else
        # Determine if we need hybrid mode
        if [ "${route_count:-0}" -le 1 ]; then
            # Single route mode - update default-ai-route
            log "Single route mode: updating default-ai-route"
            
            # Get current default route
            default_route=$(curl -s -X GET "${CONSOLE_URL}/v1/ai/routes/default-ai-route" \
                -b "${HIGRESS_COOKIE_FILE}" 2>/dev/null)
            
            if [ -z "$(echo "${default_route}" | jq -r '.data' 2>/dev/null)" ]; then
                log "Default route not found, creating..."
                # Create default route (would need full implementation)
                log "WARNING: Default route creation skipped - use Web UI or API"
            else
                log "Updating default-ai-route to use provider: ${PROVIDER}"
                # Update provider in upstreams[0]
                patched=$(echo "${default_route}" | jq --arg provider "${PROVIDER}" '
                    .data | 
                    del(.modelPredicates) |
                    .upstreams[0].provider = $provider
                ' 2>/dev/null)
                
                if [ -n "${patched}" ] && [ "${patched}" != "null" ]; then
                    update_resp=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
                        "${CONSOLE_URL}/v1/ai/routes/default-ai-route" \
                        -b "${HIGRESS_COOKIE_FILE}" \
                        -H 'Content-Type: application/json' \
                        -d "${patched}" 2>/dev/null)
                    
                    if [ "${update_resp}" = "200" ]; then
                        log "SUCCESS: default-ai-route updated"
                    else
                        log "WARNING: Route update failed (HTTP ${update_resp})"
                    fi
                fi
            fi
        else
            # Multi-route mode - create provider-specific route
            log "Multi-route mode: creating ${PROVIDER}-ai-route"
            
            AI_GATEWAY_DOMAIN="${HICLAW_AI_GATEWAY_DOMAIN:-aigw-local.hiclaw.io}"
            HICLAW_VERSION="${HICLAW_VERSION:-latest}"
            
            route_body=$(cat <<EOF
{
  "name": "${PROVIDER}-ai-route",
  "domains": ["${AI_GATEWAY_DOMAIN}"],
  "pathPredicate": {"matchType": "PRE", "matchValue": "/", "caseSensitive": false},
  "upstreams": [{"provider": "${PROVIDER}", "weight": 100, "modelMapping": {}}],
  "modelPredicates": [{"matchType": "PRE", "matchValue": "${PROVIDER}"}],
  "authConfig": {
    "enabled": true,
    "allowedCredentialTypes": ["key-auth"],
    "allowedConsumers": ["manager"]
  },
  "headerControl": {
    "enabled": true,
    "request": {
      "add": [{"key": "user-agent", "value": "HiClaw/${HICLAW_VERSION}"}],
      "set": [],
      "remove": []
    },
    "response": {"add": [], "set": [], "remove": []}
  }
}
EOF
)
            create_resp=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
                "${CONSOLE_URL}/v1/ai/routes" \
                -b "${HIGRESS_COOKIE_FILE}" \
                -H 'Content-Type: application/json' \
                -d "${route_body}" 2>/dev/null)
            
            if [ "${create_resp}" = "200" ] || [ "${create_resp}" = "201" ]; then
                log "SUCCESS: Created ${PROVIDER}-ai-route with modelPredicate"
            else
                log "WARNING: Route creation failed (HTTP ${create_resp})"
            fi
        fi
    fi
fi

MODEL_FILE="/root/hiclaw-fs/agents/${ENTITY_NAME}/model.json"
BACKUP_FILE="${MODEL_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

mkdir -p "$(dirname ${MODEL_FILE})"

if [ -f "${MODEL_FILE}" ]; then
    cp "${MODEL_FILE}" "${BACKUP_FILE}"
    log "Backup saved: ${BACKUP_FILE}"
fi

cat > "${MODEL_FILE}" <<EOF
{
  "provider": "${PROVIDER}",
  "model": "${MODEL}",
  "contextWindow": ${CONTEXT_WINDOW},
  "maxTokens": ${MAX_TOKENS},
  "reasoning": ${REASONING},
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

log "Model assignment saved to ${MODEL_FILE}"

if [ "${ENTITY_TYPE}" = "manager" ]; then
    OPENCLAW_CONFIG="/root/manager-workspace/openclaw.json"
    
    if [ -f "${OPENCLAW_CONFIG}" ]; then
        log "Updating OpenClaw config..."
        
        # Use standard hiclaw-gateway provider format
        gateway_provider="hiclaw-gateway"
        model_id="${gateway_provider}/${MODEL}"
        
        # Check if model already exists
        model_exists=$(jq --arg model "${MODEL}" \
            '.models.providers["'"${gateway_provider}"'"].models[]? | select(.id == $model) | .id' \
            "${OPENCLAW_CONFIG}" 2>/dev/null)
        
        if [ -z "${model_exists}" ]; then
            log "Adding new model to openclaw.json..."
            # Add model to the list
            jq --arg model "${MODEL}" \
               --argjson cw "${CONTEXT_WINDOW}" \
               --argjson mt "${MAX_TOKENS}" \
               --argjson reasoning "${REASONING}" \
               --arg input "$(if [ "${REASONING}" = "true" ]; then echo '["text", "image"]'; else echo '["text"]'; fi)" \
               '
                if .models.providers["'"${gateway_provider}"'"].models == null then
                    .models.providers["'"${gateway_provider}"'"].models = []
                else
                    .
                end |
                .models.providers["'"${gateway_provider}"'"].models += [{
                    "id": $model,
                    "name": $model,
                    "reasoning": $reasoning,
                    "contextWindow": $cw,
                    "maxTokens": $mt,
                    "input": ($input | fromjson)
                }]
               ' "${OPENCLAW_CONFIG}" > "${OPENCLAW_CONFIG}.tmp" && mv "${OPENCLAW_CONFIG}.tmp" "${OPENCLAW_CONFIG}"
        fi
        
        # Set as primary model
        log "Setting primary model to ${model_id}..."
        jq --arg model_id "${model_id}" \
           --arg model "${MODEL}" \
           '
            if .agents == null then .agents = {} else . end |
            if .agents.defaults == null then .agents.defaults = {} else . end |
            if .agents.defaults.model == null then .agents.defaults.model = {} else . end |
            .agents.defaults.model.primary = $model_id |
            if .agents.defaults.models == null then .agents.defaults.models = {} else . end |
            .agents.defaults.models[$model_id] = {"alias": $model}
           ' "${OPENCLAW_CONFIG}" > "${OPENCLAW_CONFIG}.tmp" && mv "${OPENCLAW_CONFIG}.tmp" "${OPENCLAW_CONFIG}"
        
        log "Triggering OpenClaw config reload..."
        curl -s -X POST "http://127.0.0.1:18799/api/reload" 2>/dev/null || true
        
        log "Manager model updated and reloaded successfully"
    else
        log "ERROR: OpenClaw config not found at ${OPENCLAW_CONFIG}"
        exit 1
    fi
else
    # Worker: update openclaw.json in MinIO
    WORKER_OPENCLAW="/root/hiclaw-fs/agents/${ENTITY_NAME}/openclaw.json"
    
    if [ -f "${WORKER_OPENCLAW}" ]; then
        log "Updating Worker openclaw.json..."
        
        gateway_provider="hiclaw-gateway"
        model_id="${gateway_provider}/${MODEL}"
        
        model_exists=$(jq --arg model "${MODEL}" \
            '.models.providers["'"${gateway_provider}"'"].models[]? | select(.id == $model) | .id' \
            "${WORKER_OPENCLAW}" 2>/dev/null)
        
        if [ -z "${model_exists}" ]; then
            jq --arg model "${MODEL}" \
               --argjson cw "${CONTEXT_WINDOW}" \
               --argjson mt "${MAX_TOKENS}" \
               --argjson reasoning "${REASONING}" \
               '
                if .models.providers["'"${gateway_provider}"'"].models == null then
                    .models.providers["'"${gateway_provider}"'"].models = []
                else
                    .
                end |
                .models.providers["'"${gateway_provider}"'"].models += [{
                    "id": $model,
                    "name": $model,
                    "reasoning": $reasoning,
                    "contextWindow": $cw,
                    "maxTokens": $mt,
                    "input": ["text"]
                }] |
                if .agents == null then .agents = {} else . end |
                if .agents.defaults == null then .agents.defaults = {} else . end |
                if .agents.defaults.models == null then .agents.defaults.models = {} else . end |
                .agents.defaults.models[$model] = {"alias": $model}
               ' "${WORKER_OPENCLAW}" > "${WORKER_OPENCLAW}.tmp" && mv "${WORKER_OPENCLAW}.tmp" "${WORKER_OPENCLAW}"
            
            # Sync to MinIO
            log "Syncing to MinIO..."
            mc cp "${WORKER_OPENCLAW}" "${HICLAW_STORAGE_PREFIX}/agents/${ENTITY_NAME}/openclaw.json" 2>/dev/null \
                || log "WARNING: Failed to sync to MinIO"
            
            log "Worker model updated successfully"
        else
            log "Worker model already exists in config"
        fi
    else
        log "WARNING: Worker openclaw.json not found (Worker may not be created yet)"
    fi
fi

log "Done!"
