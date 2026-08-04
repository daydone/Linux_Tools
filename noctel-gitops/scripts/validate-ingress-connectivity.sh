#!/bin/bash
# Validate critical ingress connectivity for prod and qa
# Tests: API health, desk UI, and chirpstack websocket endpoints
# Run before and after changes to confirm no connectivity breaks

set -e

echo "=== Production & QA Ingress Connectivity Validation ==="
echo "Testing at: $(date)"
echo ""

# HTTP/HTTPS endpoints
HTTP_ENDPOINTS=(
  "PROD"
  "https://pdx1-prod-api.telnoc.com/health"
  "https://pdx1-prod-desk.telnoc.com/"
  "QA"
  "https://pdx1-qa-display.telnoc.com/"
)

# WebSocket endpoints
WS_ENDPOINTS=(
  "PROD"
  "ws://10.0.99.80:3001/"
  "QA"
  "ws://10.0.98.80:3001/"
)

FAILED=0
PASSED=0

# Test HTTP/HTTPS endpoints
for endpoint in "${HTTP_ENDPOINTS[@]}"; do
  if [[ "$endpoint" =~ ^(PROD|QA)$ ]]; then
    echo ""
    echo "=== $endpoint ==="
    continue
  fi

  echo -n "Testing $endpoint ... "

  status=$(curl -s -o /dev/null -w "%{http_code}" -k -L "$endpoint" 2>/dev/null || echo "000")

  if [[ "$status" =~ ^(200|301|302|303|307|308|401|403)$ ]]; then
    echo "✓ OK (HTTP $status)"
    ((PASSED++))
  else
    echo "✗ FAILED (HTTP $status)"
    ((FAILED++))
  fi
done

# Test WebSocket endpoints
echo ""
echo "=== WebSocket Endpoints ==="
for i in "${!WS_ENDPOINTS[@]}"; do
  endpoint="${WS_ENDPOINTS[$i]}"

  if [[ "$endpoint" =~ ^(PROD|QA)$ ]]; then
    echo ""
    echo "=== $endpoint ==="
    continue
  fi

  echo -n "Testing $endpoint ... "
  # Capture entire response, then check for 101 in first line
  ws_response=$(curl -s --max-time 2 -i -N \
    -H "Connection: upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
    -H "Sec-WebSocket-Version: 13" \
    "$endpoint" 2>&1 | head -1)

  if [ "$(echo "$ws_response" | grep -o "101")" = "101" ]; then
    echo "✓ OK (WebSocket upgrade)"
    ((PASSED++))
  else
    echo "✗ FAILED (got: $ws_response)"
    ((FAILED++))
  fi
done

echo ""
echo "=== Results ==="
echo "Passed: $PASSED / 5"
echo "Failed: $FAILED / 5"

if [ $FAILED -gt 0 ]; then
  echo ""
  echo "⚠️  INGRESS CONNECTIVITY ISSUE DETECTED"
  echo "Troubleshooting:"
  echo "  kubectl get ingress -n prod -n qa"
  echo "  kubectl get svc -A | grep 10.0.99.80"
  echo "  kubectl get svc -A | grep 10.0.98.80"
  echo "  kubectl logs -n ingress-traefik -l app=traefik --tail=50"
  exit 1
fi

echo ""
echo "✓ All critical ingresses (prod and qa) responding"
exit 0
