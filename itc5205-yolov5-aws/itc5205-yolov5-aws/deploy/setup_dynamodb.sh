#!/usr/bin/env bash
# DynamoDB table with provisioned capacity and target-tracking auto scaling
# (1-10 RCU/WCU, 70 % target). Run from: AWS CloudShell.
set -euo pipefail

REGION="us-east-1"
TABLE="itc5205-yolo-detections"

aws dynamodb create-table --table-name "${TABLE}" \
  --attribute-definitions AttributeName=request_id,AttributeType=S \
  --key-schema AttributeName=request_id,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1 \
  --region "${REGION}" >/dev/null
aws dynamodb wait table-exists --table-name "${TABLE}" --region "${REGION}"

for DIM in Read Write; do
  aws application-autoscaling register-scalable-target --service-namespace dynamodb \
    --resource-id "table/${TABLE}" --scalable-dimension "dynamodb:table:${DIM}CapacityUnits" \
    --min-capacity 1 --max-capacity 10 --region "${REGION}"
  aws application-autoscaling put-scaling-policy --service-namespace dynamodb \
    --resource-id "table/${TABLE}" --scalable-dimension "dynamodb:table:${DIM}CapacityUnits" \
    --policy-name "${TABLE}-${DIM,,}-scaling" --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration \
    "{\"TargetValue\":70.0,\"PredefinedMetricSpecification\":{\"PredefinedMetricType\":\"DynamoDB${DIM}CapacityUtilization\"}}" \
    --region "${REGION}" >/dev/null
done
echo "Table ${TABLE} created with auto scaling"
