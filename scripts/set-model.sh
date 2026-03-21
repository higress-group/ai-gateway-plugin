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
#   --max-tokens  Max output tokens (default: 8192)
#   --reasoning   Enable reasoning mode (true/false, default: false)

set -e
source /opt/hiclaw/scripts/lib/base.sh

TARGET=""
PROVIDER=""
MODEL=""
CONTEXT_WINDOW=200000
MAX_TOKENS=8192
REASONING=false

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
    echo "Usage: $0 --target <manager|worker:name> --provider <name> --model <id>"
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
        
        model_exists=$(jq --arg model "${MODEL}" '.models | map(.id) | index($model)' "${OPENCLAW_CONFIG}" 2>/dev/null || echo "null")
        
        if [ "${model_exists}" = "null" ] || [ -z "${model_exists}" ]; then
            jq --arg model "${MODEL}" --argjson cw "${CONTEXT_WINDOW}" --argjson mt "${MAX_TOKENS}" --argjson reasoning "${REASONING}" '
                .models += [{
                    "id": $model,
                    "contextWindow": $cw,
                    "maxTokens": $mt,
                    "reasoning": $reasoning
                }] |
                .agents.defaults.model.primary = $model
            ' "${OPENCLAW_CONFIG}" > "${OPENCLAW_CONFIG}.tmp" && mv "${OPENCLAW_CONFIG}.tmp" "${OPENCLAW_CONFIG}"
        else
            jq --arg model "${MODEL}" '
                .agents.defaults.model.primary = $model
            ' "${OPENCLAW_CONFIG}" > "${OPENCLAW_CONFIG}.tmp" && mv "${OPENCLAW_CONFIG}.tmp" "${OPENCLAW_CONFIG}"
        fi
        
        log "Triggering OpenClaw config reload..."
        curl -s -X POST "http://127.0.0.1:18799/api/reload" 2>/dev/null || true
        
        log "Manager model updated and reloaded"
    fi
else
    log "Worker model assignment saved (will apply on next task)"
fi

log "Done!"
