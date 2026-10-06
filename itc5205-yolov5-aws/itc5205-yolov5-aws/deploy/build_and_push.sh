#!/usr/bin/env bash
# Build the Lambda container image on the EC2 builder and push it to ECR.
# Run on: itc5205-yolo-builder (Ubuntu 24.04, Docker, role itc5205-yolo-ec2-role)
# Usage:  bash deploy/build_and_push.sh [tag]      (default tag: v2)
set -euo pipefail

TAG="${1:-v2}"
REGION="us-east-1"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
REPO="${REGISTRY}/itc5205-yolov5-lambda"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${HOME}/lambda-build"

# 1. Build context: YOLOv5 source + weights + our code
if [ ! -d "${HOME}/yolov5" ]; then
  git clone https://github.com/ultralytics/yolov5 "${HOME}/yolov5"
fi
if [ ! -f "${HOME}/yolov5/yolov5s.pt" ]; then
  curl -L -o "${HOME}/yolov5/yolov5s.pt" \
    https://github.com/ultralytics/yolov5/releases/download/v7.0/yolov5s.pt
fi
rm -rf "${BUILD}" && mkdir -p "${BUILD}"
cp -r "${HOME}/yolov5" "${BUILD}/yolov5"
rm -rf "${BUILD}/yolov5/.git" "${BUILD}/yolov5/runs"
cp "${HOME}/yolov5/yolov5s.pt" "${BUILD}/"
cp "${REPO_ROOT}/code/app.py" "${REPO_ROOT}/code/Dockerfile" "${BUILD}/"

# 2. Build (provenance off: Lambda rejects attestation manifests)
cd "${BUILD}"
sudo docker build --provenance=false -t "itc5205-yolov5-lambda:${TAG}" .

# 3. Push to ECR
aws ecr describe-repositories --repository-names itc5205-yolov5-lambda --region "${REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name itc5205-yolov5-lambda --region "${REGION}" >/dev/null
aws ecr get-login-password --region "${REGION}" | sudo docker login --username AWS --password-stdin "${REGISTRY}"
sudo docker tag "itc5205-yolov5-lambda:${TAG}" "${REPO}:${TAG}"
sudo docker push "${REPO}:${TAG}"
echo "Pushed ${REPO}:${TAG}"
