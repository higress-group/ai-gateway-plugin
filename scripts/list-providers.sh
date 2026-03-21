#!/bin/bash
# list-providers.sh - List all AI providers
#
# Usage: list-providers.sh [--json]
#
# Output: JSON array of providers

set -e
source /opt/hiclaw/scripts/lib/base.sh

CONSOLE_URL="http://127.0.0.1:8001"
HIGRESS_COOKIE_FILE="${HIGRESS_COOKIE_FILE:-/tmp/higress-cookie.txt}"

JSON_OUTPUT=false
if [ "$1" = "--json" ]; then
    JSON_OUTPUT=true
fi

response=$(curl -s -X GET "${CONSOLE_URL}/v1/ai/providers" \
    -b "${HIGRESS_COOKIE_FILE}" \
    -H 'Content-Type: application/json' 2>/dev/null)

if $JSON_OUTPUT; then
    echo "$response"
else
    echo "$response" | jq -r '.data[]? | "\(.name)\t\(.type)\t\((.tokens | length)) tokens"' 2>/dev/null || \
    echo "$response" | jq -r '.[]? | "\(.name)\t\(.type)\t\((.tokens | length)) tokens"' 2>/dev/null || \
    echo "Failed to parse response"
fi
