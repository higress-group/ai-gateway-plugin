#!/bin/bash
# create-provider.sh - Create a new AI provider
#
# Usage: create-provider.sh --type <TYPE> --name <NAME> --token <TOKEN> [--url <URL>]
#
# Examples:
#   create-provider.sh --type qwen --name qwen --token "sk-xxx"
#   create-provider.sh --type openai --name openai --token "sk-xxx" --url "https://api.openai.com/v1"

set -e
source /opt/hiclaw/scripts/lib/base.sh

CONSOLE_URL="http://127.0.0.1:8001"
HIGRESS_COOKIE_FILE="${HIGRESS_COOKIE_FILE:-/tmp/higress-cookie.txt}"

PROVIDER_TYPE=""
PROVIDER_NAME=""
PROVIDER_TOKEN=""
CUSTOM_URL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --type)  PROVIDER_TYPE="$2"; shift 2 ;;
        --name)  PROVIDER_NAME="$2"; shift 2 ;;
        --token) PROVIDER_TOKEN="$2"; shift 2 ;;
        --url)   CUSTOM_URL="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "${PROVIDER_TYPE}" ] || [ -z "${PROVIDER_NAME}" ] || [ -z "${PROVIDER_TOKEN}" ]; then
    echo "Usage: create-provider.sh --type <TYPE> --name <NAME> --token <TOKEN> [--url <URL>]"
    exit 1
fi

# Build provider config
PROVIDER_BODY=$(cat <<EOF
{
  "type": "${PROVIDER_TYPE}",
  "name": "${PROVIDER_NAME}",
  "tokens": ["${PROVIDER_TOKEN}"],
  "protocol": "openai/v1",
  "tokenFailoverConfig": {"enabled": false},
  "rawConfigs": {
    $(if [ -n "${CUSTOM_URL}" ]; then
        echo "\"apiUrl\": \"${CUSTOM_URL}\","
    elif [ "${PROVIDER_TYPE}" = "qwen" ]; then
        echo "\"qwenEnableSearch\": false, \"qwenEnableCompatible\": true, \"qwenFileIds\": [],"
    fi)
    "mergeConsecutiveMessages": true
  }
}
EOF
)

response=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${CONSOLE_URL}/v1/ai/providers" \
    -b "${HIGRESS_COOKIE_FILE}" \
    -H 'Content-Type: application/json' \
    -d "${PROVIDER_BODY}" 2>/dev/null)

if [ "${response}" = "200" ] || [ "${response}" = "201" ]; then
    echo "SUCCESS: Provider '${PROVIDER_NAME}' created"
    exit 0
elif [ "${response}" = "409" ]; then
    echo "WARNING: Provider '${PROVIDER_NAME}' already exists"
    exit 0
else
    echo "ERROR: Failed to create provider (HTTP ${response})"
    exit 1
fi
