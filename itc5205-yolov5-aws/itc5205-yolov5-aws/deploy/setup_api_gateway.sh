#!/usr/bin/env bash
# Create the REST API, request model, POST /detect (Lambda proxy), API key and
# usage plan, then deploy to stage "prod". Reproduces the console setup used in
# the report (including the AWS_PROXY + request-model fix from Section 4.5).
# Run from: AWS CloudShell.   Usage:  bash deploy/setup_api_gateway.sh
set -euo pipefail

REGION="us-east-1"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
FN_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:itc5205-yolov5-detector"
HERE="$(cd "$(dirname "$0")" && pwd)"

API_ID=$(aws apigateway create-rest-api --name itc5205-yolo-api \
  --endpoint-configuration types=REGIONAL --region "${REGION}" --query id --output text)
ROOT_ID=$(aws apigateway get-resources --rest-api-id "${API_ID}" --region "${REGION}" \
  --query 'items[?path==`/`].id' --output text)

aws apigateway create-model --rest-api-id "${API_ID}" --name DetectRequest \
  --content-type application/json --schema "file://${HERE}/api/detect-request-model.json" \
  --region "${REGION}" >/dev/null
VALIDATOR_ID=$(aws apigateway create-request-validator --rest-api-id "${API_ID}" \
  --name validate-body --validate-request-body --no-validate-request-parameters \
  --region "${REGION}" --query id --output text)

RES_ID=$(aws apigateway create-resource --rest-api-id "${API_ID}" --parent-id "${ROOT_ID}" \
  --path-part detect --region "${REGION}" --query id --output text)
aws apigateway put-method --rest-api-id "${API_ID}" --resource-id "${RES_ID}" \
  --http-method POST --authorization-type NONE --api-key-required \
  --request-validator-id "${VALIDATOR_ID}" \
  --request-models '{"application/json":"DetectRequest"}' --region "${REGION}" >/dev/null
aws apigateway put-integration --rest-api-id "${API_ID}" --resource-id "${RES_ID}" \
  --http-method POST --type AWS_PROXY --integration-http-method POST \
  --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${FN_ARN}/invocations" \
  --region "${REGION}" >/dev/null

# Allow only this API's POST /detect to invoke the function
aws lambda add-permission --function-name itc5205-yolov5-detector \
  --statement-id "apigw-${API_ID}-detect" --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*/POST/detect" \
  --region "${REGION}" >/dev/null

aws apigateway create-deployment --rest-api-id "${API_ID}" --stage-name prod --region "${REGION}" >/dev/null

KEY_ID=$(aws apigateway create-api-key --name itc5205-client-key --enabled \
  --region "${REGION}" --query id --output text)
PLAN_ID=$(aws apigateway create-usage-plan --name itc5205-plan \
  --throttle burstLimit=20,rateLimit=10 --quota limit=5000,period=MONTH \
  --api-stages "apiId=${API_ID},stage=prod" --region "${REGION}" --query id --output text)
aws apigateway create-usage-plan-key --usage-plan-id "${PLAN_ID}" --key-id "${KEY_ID}" \
  --key-type API_KEY --region "${REGION}" >/dev/null

echo "Invoke URL: https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod/detect"
echo "API key id: ${KEY_ID}  (value: aws apigateway get-api-key --api-key ${KEY_ID} --include-value)"
