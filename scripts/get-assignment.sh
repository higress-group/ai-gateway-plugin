#!/bin/bash
# get-assignment.sh - Get current model assignment for Manager or Worker
#
# Usage: get-assignment.sh <manager|worker:NAME> [--json]
#
# Examples:
#   get-assignment.sh manager
#   get-assignment.sh worker:alice --json

set -e
source /opt/hiclaw/scripts/lib/base.sh

CONSOLE_URL="http://127.0.0.1:8001"
HIGRESS_COOKIE_FILE="${HIGRESS_COOKIE_FILE:-/tmp/higress-cookie.txt}"

TARGET=""
JSON_OUTPUT=false

while [ $# -gt 0 ]; do
    case "$1" in
        --json) JSON_OUTPUT=true; shift ;;
        *)      TARGET="$1"; shift ;;
    esac
done

if [ -z "${TARGET}" ]; then
    echo "Usage: get-assignment.sh <manager|worker:NAME> [--json]"
    exit 1
fi

# Parse target
if [ "${TARGET}" = "manager" ]; then
    TARGET_TYPE="manager"
    TARGET_NAME="manager"
elif [[ "${TARGET}" == worker:* ]]; then
    TARGET_TYPE="worker"
    TARGET_NAME="${TARGET#worker:}"
else
    echo "ERROR: Invalid target format. Use 'manager' or 'worker:NAME'"
    exit 1
fi

if [ "${TARGET_TYPE}" = "manager" ]; then
    # Get Manager model from AI route
    route_response=$(curl -s -X GET "${CONSOLE_URL}/v1/ai/routes/default-ai-route" \
        -b "${HIGRESS_COOKIE_FILE}" 2>/dev/null)
    
    provider=$(echo "${route_response}" | jq -r '.data.upstreams[0].provider // "unknown"' 2>/dev/null)
    
    # Get model from openclaw.json
    OPENCLAW_CONFIG="${OPENCLAW_CONFIG_PATH:-/root/manager-workspace/openclaw.json}"
    if [ -f "${OPENCLAW_CONFIG}" ]; then
        model=$(jq -r '.agents.defaults.model.primary // "unknown"' "${OPENCLAW_CONFIG}" 2>/dev/null)
        context_window=$(jq -r '.models[] | select(.id == $model) | .contextWindow // 200000' --arg model "${model}" "${OPENCLAW_CONFIG}" 2>/dev/null || echo "200000")
    else
        model="unknown"
        context_window="unknown"
    fi
    
    if $JSON_OUTPUT; then
        jq -n \
            --arg provider "${provider}" \
            --arg model "${model}" \
            --arg context "${context_window}" \
            '{target: "manager", provider: $provider, model: $model, contextWindow: ($context | tonumber)}'
    else
        echo "Manager Model Assignment:"
        echo "  Provider: ${provider}"
        echo "  Model: ${model}"
        echo "  Context Window: ${context_window}"
    fi
    
else
    # Get Worker model from stored file
    WORKER_NAME="${TARGET_NAME}"
    MODEL_FILE="/root/hiclaw-fs/agents/${WORKER_NAME}/model.json"
    
    if [ -f "${MODEL_FILE}" ]; then
        if $JSON_OUTPUT; then
            jq '.' "${MODEL_FILE}"
        else
            echo "Worker '${WORKER_NAME}' Model Assignment:"
            jq -r '"  Provider: \(.provider)\n  Model: \(.model)\n  Context Window: \(.contextWindow)\n  Updated: \(.updatedAt)"' "${MODEL_FILE}"
        fi
    else
        if $JSON_OUTPUT; then
            jq -n --arg name "${WORKER_NAME}" '{error: "Worker model assignment not found", worker: $name}'
        else
            echo "Worker '${WORKER_NAME}' has no model assignment stored"
        fi
    fi
fi
