#!/usr/bin/env bash
# Create or update the Lambda function from the ECR image.
# Run from: AWS CloudShell (console user). The EC2 builder role is NOT allowed
# to change Lambda functions by design.
# Usage:  bash deploy/deploy_lambda.sh [tag]      (default tag: v2)
set -euo pipefail

TAG="${1:-v2}"
REGION="us-east-1"
FN="itc5205-yolov5-detector"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
IMAGE="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/itc5205-yolov5-lambda:${TAG}"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/itc5205-yolo-lambda-role"
ENV="Variables={BUCKET_NAME=itc5205-yolo-250014,CONF_THRESHOLD=0.25,TABLE_NAME=itc5205-yolo-detections}"

if aws lambda get-function --function-name "${FN}" --region "${REGION}" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "${FN}" --image-uri "${IMAGE}" \
    --region "${REGION}" --query LastUpdateStatus
  aws lambda wait function-updated --function-name "${FN}" --region "${REGION}"
else
  aws lambda create-function --function-name "${FN}" --package-type Image \
    --code ImageUri="${IMAGE}" --role "${ROLE_ARN}" --architectures x86_64 \
    --region "${REGION}" --query State
  aws lambda wait function-active-v2 --function-name "${FN}" --region "${REGION}"
fi

# 3008 MB (2048 MB is the measured best price/performance), 120 s timeout
aws lambda update-function-configuration --function-name "${FN}" \
  --memory-size 3008 --timeout 120 --environment "${ENV}" \
  --region "${REGION}" --query LastUpdateStatus
aws lambda wait function-updated --function-name "${FN}" --region "${REGION}"

# Warm-up call after every deployment (first cold start after a new image took 19.4 s)
aws lambda invoke --function-name "${FN}" --region "${REGION}" --cli-read-timeout 150 \
  --cli-binary-format raw-in-base64-out --payload '{"body":"{\"key\":\"input/bus.jpg\"}"}' \
  /tmp/warmup.json >/dev/null && echo "Deployed ${IMAGE} and warmed up"
