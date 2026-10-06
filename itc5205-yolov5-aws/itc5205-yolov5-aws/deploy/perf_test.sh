#!/usr/bin/env bash
# ITC5205 Assignment 2 - performance & scaling tests (Student ID: 250014)
#
# Usage (run in AWS CloudShell, us-east-1):
#   export API_KEY=<your key>
#   bash perf_test.sh dataset          # download COCO images + edge cases, upload to S3
#   bash perf_test.sh batch            # run every dataset image through the API
#   bash perf_test.sh memory           # memory sweep 1024 / 2048 / 3008 MB
#   bash perf_test.sh coldstart        # force 3 cold starts and compare with warm calls
#   bash perf_test.sh load [N] [C]     # N requests at concurrency C (default 40 / 8)
#   bash perf_test.sh metrics          # CloudWatch summary for the last 3 hours
#
# Every test writes a CSV into ./perf_results/ for the report charts.

set -u
API_URL="${API_URL:-https://lav5va3cge.execute-api.us-east-1.amazonaws.com/prod/detect}"
FN="itc5205-yolov5-detector"
BUCKET="itc5205-yolo-250014"
TABLE="itc5205-yolo-detections"
REGION="us-east-1"
OUT="perf_results"
ENV_BASE="BUCKET_NAME=$BUCKET,CONF_THRESHOLD=0.25,TABLE_NAME=$TABLE"
PRICE_GB_S="0.0000166667"     # Lambda x86 price per GB-second (us-east-1)
PRICE_REQ="0.20"              # Lambda price per 1M requests
mkdir -p "$OUT"

need_key() {
  if [ -z "${API_KEY:-}" ]; then echo "Set the key first:  export API_KEY=<your key>"; exit 1; fi
}

# call_api <s3-key> -> prints "http_code client_seconds" and leaves the body in /tmp/resp.json
call_api() {
  curl -s -m 60 -o /tmp/resp.json -w '%{http_code} %{time_total}' -X POST "$API_URL" \
    -H "x-api-key: $API_KEY" -H "Content-Type: application/json" -d "{\"key\":\"$1\"}"
}

# field <name> -> value from /tmp/resp.json (blank if absent)
field() {
  python3 - "$1" <<'PY'
import json, sys
try:
    r = json.load(open("/tmp/resp.json"))
except Exception:
    print(""); sys.exit()
path = sys.argv[1].split(".")
for p in path:
    r = r.get(p, "") if isinstance(r, dict) else ""
print(json.dumps(r) if isinstance(r, (dict, list)) else r)
PY
}

wait_updated() { aws lambda wait function-updated --function-name "$FN" --region "$REGION"; }

direct_warmup() {   # invoke Lambda directly (no 29 s API Gateway limit) so the environment is warm
  aws lambda invoke --function-name "$FN" --region "$REGION" --cli-read-timeout 150 \
    --cli-binary-format raw-in-base64-out --payload '{"body":"{\"key\":\"input/bus.jpg\"}"}' \
    /tmp/warm.json >/dev/null && echo "  warm-up done"
}

# ---------------------------------------------------------------------------
cmd_dataset() {
  mkdir -p dataset && cd dataset || exit 1
  # COCO val2017 images (Lin et al., 2014) - varied scenes: people, animals, vehicles, indoor
  for id in 000000000139 000000000285 000000000632 000000000724 000000000776 \
            000000000785 000000000802 000000000872 000000000885 000000039769; do
    [ -f "$id.jpg" ] || curl -s -f -O "http://images.cocodataset.org/val2017/$id.jpg" \
      && echo "  downloaded $id.jpg" || echo "  could not download $id.jpg"
  done
  # edge cases
  : > edge_empty.jpg                                   # 0-byte file
  echo "this is not an image" > edge_fake.jpg          # text file with an image extension
  cd ..
  aws s3 cp dataset/ "s3://$BUCKET/input/dataset/" --recursive --only-show-errors
  echo
  aws s3 ls "s3://$BUCKET/input/dataset/" --human-readable
}

cmd_batch() {
  need_key
  local csv="$OUT/batch_results.csv"
  echo "file,http,client_s,objects,inference_ms,total_ms,cold_start,counts" > "$csv"
  printf "%-26s %-5s %-9s %-8s %-10s %s\n" FILE HTTP CLIENT_S OBJECTS INFER_MS COUNTS
  for k in $(aws s3 ls "s3://$BUCKET/input/dataset/" | awk '{print $4}'); do
    read -r code t <<< "$(call_api "input/dataset/$k")"
    local objs inf tot cold counts
    objs=$(field object_count); inf=$(field timing_ms.inference); tot=$(field timing_ms.total)
    cold=$(field cold_start); counts=$(field counts)
    [ -z "$counts" ] && counts=$(field error)
    printf "%-26s %-5s %-9s %-8s %-10s %s\n" "$k" "$code" "$t" "$objs" "$inf" "$counts"
    echo "$k,$code,$t,$objs,$inf,$tot,$cold,\"${counts//\"/\'}\"" >> "$csv"
  done
  echo; echo "Saved $csv"
}

cmd_memory() {
  need_key
  local csv="$OUT/memory_sweep.csv" orig
  orig=$(aws lambda get-function-configuration --function-name "$FN" --query MemorySize --output text)
  echo "memory_mb,run,http,client_s,inference_ms,total_ms" > "$csv"
  for mem in 1024 2048 3008; do
    echo "== Memory $mem MB =="
    aws lambda update-function-configuration --function-name "$FN" --memory-size "$mem" >/dev/null
    wait_updated; direct_warmup
    for i in 1 2 3 4 5; do
      read -r code t <<< "$(call_api input/bus.jpg)"
      local inf tot; inf=$(field timing_ms.inference); tot=$(field timing_ms.total)
      echo "  run $i: HTTP $code  client ${t}s  inference ${inf} ms  handler ${tot} ms"
      echo "$mem,$i,$code,$t,$inf,$tot" >> "$csv"
    done
  done
  aws lambda update-function-configuration --function-name "$FN" --memory-size "$orig" >/dev/null
  wait_updated
  echo; echo "Memory restored to $orig MB"; echo
  python3 - "$csv" "$PRICE_GB_S" "$PRICE_REQ" <<'PY'
import csv, sys, statistics as st
rows = [r for r in csv.DictReader(open(sys.argv[1])) if r["http"] == "200" and r["total_ms"]]
gb_s, per_req = float(sys.argv[2]), float(sys.argv[3])
print(f"{'MEMORY':>7} {'AVG INFER ms':>13} {'AVG HANDLER ms':>15} {'AVG CLIENT s':>13} {'COST / 1M req (USD)':>20}")
for mem in sorted({int(r["memory_mb"]) for r in rows}):
    g = [r for r in rows if int(r["memory_mb"]) == mem]
    inf = st.mean(float(r["inference_ms"]) for r in g)
    tot = st.mean(float(r["total_ms"]) for r in g)
    cli = st.mean(float(r["client_s"]) for r in g)
    cost = (tot / 1000) * (mem / 1024) * gb_s * 1_000_000 + per_req
    print(f"{mem:>7} {inf:>13.1f} {tot:>15.1f} {cli:>13.3f} {cost:>20.2f}")
PY
  echo; echo "Saved $csv"
}

cmd_coldstart() {
  need_key
  local csv="$OUT/coldstart.csv"
  echo "trial,call,http,client_s,cold_start,model_load_ms,inference_ms,total_ms" > "$csv"
  for trial in 1 2 3; do
    echo "== Trial $trial: forcing a new execution environment =="
    aws lambda update-function-configuration --function-name "$FN" \
      --environment "Variables={$ENV_BASE,COLD_MARK=$(date +%s)}" >/dev/null
    wait_updated
    for call in cold warm1 warm2; do
      read -r code t <<< "$(call_api input/bus.jpg)"
      if [ "$code" = "504" ]; then
        echo "  $call: HTTP 504 after ${t}s - API Gateway 29 s limit hit during cold start"
        echo "$trial,$call,$code,$t,,,," >> "$csv"; sleep 20; continue
      fi
      local cs ml inf tot
      cs=$(field cold_start); ml=$(field model_load_ms); inf=$(field timing_ms.inference); tot=$(field timing_ms.total)
      echo "  $call: HTTP $code  client ${t}s  cold_start=$cs  model_load ${ml} ms  inference ${inf} ms"
      echo "$trial,$call,$code,$t,$cs,$ml,$inf,$tot" >> "$csv"
    done
  done
  aws lambda update-function-configuration --function-name "$FN" \
    --environment "Variables={$ENV_BASE}" >/dev/null; wait_updated
  echo; echo "Init Duration from CloudWatch REPORT lines (last 30 min):"
  aws logs filter-log-events --log-group-name "/aws/lambda/$FN" --filter-pattern '"Init Duration"' \
    --start-time $(( ($(date +%s) - 1800) * 1000 )) --query 'events[].message' --output text \
    | grep -o 'Duration: [0-9.]* ms.*Init Duration: [0-9.]* ms' | sed 's/\t/ /g'
  echo; echo "Saved $csv"
}

cmd_load() {
  need_key
  local n="${1:-40}"
  local c="${2:-8}"
  local raw="$OUT/load_${n}x${c}.txt"
  echo "Lambda account concurrency limit: $(aws lambda get-account-settings --query AccountLimit.ConcurrentExecutions --output text)"
  echo "Sending $n requests at concurrency $c ..."
  local start end
  start=$(date +%s.%N)
  seq "$n" | xargs -P "$c" -I{} curl -s -m 60 -o /dev/null -w '%{http_code} %{time_total}\n' \
    -X POST "$API_URL" -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
    -d '{"key":"input/bus.jpg"}' > "$raw"
  end=$(date +%s.%N)
  python3 - "$raw" "$start" "$end" "$n" "$c" <<'PY'
import sys, statistics as st, collections
lines = [l.split() for l in open(sys.argv[1]) if l.strip()]
wall = float(sys.argv[3]) - float(sys.argv[2])
codes = collections.Counter(c for c, _ in lines)
ok = sorted(float(t) for c, t in lines if c == "200")
print(f"\nRequests: {sys.argv[4]}   Concurrency: {sys.argv[5]}   Wall time: {wall:.1f}s")
print("Status codes:", dict(codes))
print(f"Success rate: {100*len(ok)/len(lines):.1f}%   Throughput: {len(ok)/wall:.2f} successful req/s")
if ok:
    p = lambda q: ok[min(len(ok)-1, int(q*len(ok)))]
    print(f"Latency (200s): avg {st.mean(ok):.3f}s  p50 {p(.5):.3f}s  p95 {p(.95):.3f}s  max {ok[-1]:.3f}s")
if "429" in codes:
    print("429 = API Gateway usage-plan throttling (10 req/s, burst 20) rejecting excess traffic as designed")
PY
  echo "Raw results saved to $raw"
}

cmd_metrics() {
  local s e
  s=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ); e=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "Lambda $FN (last 3 h)"
  for m in "Invocations Sum" "Errors Sum" "Throttles Sum" "Duration Average" "Duration Maximum" "ConcurrentExecutions Maximum"; do
    set -- $m
    v=$(aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name "$1" \
        --dimensions Name=FunctionName,Value="$FN" --start-time "$s" --end-time "$e" \
        --period 10800 --statistics "$2" --query "Datapoints[0].$2" --output text)
    printf "  %-22s %-8s %s\n" "$1" "$2" "$v"
  done
  echo "API Gateway itc5205-yolo-api / prod (last 3 h)"
  for m in "Count Sum" "4XXError Sum" "5XXError Sum" "Latency Average" "IntegrationLatency Average"; do
    set -- $m
    v=$(aws cloudwatch get-metric-statistics --namespace AWS/ApiGateway --metric-name "$1" \
        --dimensions Name=ApiName,Value=itc5205-yolo-api Name=Stage,Value=prod \
        --start-time "$s" --end-time "$e" --period 10800 --statistics "$2" \
        --query "Datapoints[0].$2" --output text)
    printf "  %-22s %-8s %s\n" "$1" "$2" "$v"
  done
  echo "DynamoDB rows: $(aws dynamodb scan --table-name "$TABLE" --select COUNT --query Count --output text)"
}

case "${1:-}" in
  dataset)   cmd_dataset ;;
  batch)     cmd_batch ;;
  memory)    cmd_memory ;;
  coldstart) cmd_coldstart ;;
  load)      shift; cmd_load "$@" ;;
  metrics)   cmd_metrics ;;
  *) sed -n '2,13p' "$0" ;;
esac
