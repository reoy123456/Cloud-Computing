#!/usr/bin/env bash
# ITC5205 Assignment 2 - API Gateway functional tests (Student ID: 250014)
# Usage:  bash api_test.sh <API_KEY>
# The key is passed as an argument so it is never stored in the repository.

API_URL="${API_URL:-https://lav5va3cge.execute-api.us-east-1.amazonaws.com/prod/detect}"
API_KEY="${1:-$API_KEY}"

if [ -z "$API_KEY" ]; then
  echo "Usage: bash api_test.sh <API_KEY>"
  exit 1
fi

run() {
  local title="$1" expect="$2"; shift 2
  echo
  echo "== $title (expect $expect) =="
  local out code time
  out=$(curl -s -m 60 -w $'\n%{http_code} %{time_total}' -X POST "$API_URL" \
        -H "Content-Type: application/json" "$@")
  code=$(echo "$out" | tail -n1 | cut -d' ' -f1)
  time=$(echo "$out" | tail -n1 | cut -d' ' -f2)
  echo "$out" | sed '$d' | cut -c1-300
  if [ "$code" = "$expect" ]; then r="PASS"; else r="FAIL"; fi
  echo "HTTP $code | ${time}s | $r"
}

echo "Endpoint: $API_URL"
echo "Run at:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"

run "1. Valid request"                       200 -H "x-api-key: $API_KEY" -d '{"key":"input/bus.jpg"}'
run "2. No API key"                          403                          -d '{"key":"input/bus.jpg"}'
run "3. Invalid body (API Gateway validator)" 400 -H "x-api-key: $API_KEY" -d '{"image":"bus.jpg"}'
run "4. Wrong file type (Lambda)"            415 -H "x-api-key: $API_KEY" -d '{"key":"input/notes.txt"}'
run "5. Missing image (Lambda)"              404 -H "x-api-key: $API_KEY" -d '{"key":"input/nothere.jpg"}'
echo
