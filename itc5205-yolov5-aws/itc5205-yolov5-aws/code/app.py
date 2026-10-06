"""ITC5205 Assignment 2 - YOLOv5 object detection on AWS Lambda (container image).
Student ID: 250014

Flow: API Gateway / S3 event -> read image from S3 -> YOLOv5 inference
      -> JSON + annotated image written to S3 -> record written to DynamoDB.
"""
import time

_T_INIT = time.perf_counter()  # start of init phase (used for the warm-up budget)

import base64
import io
import json
import logging
import os
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import unquote_plus

import boto3
import torch
from botocore.config import Config
from botocore.exceptions import ClientError
from PIL import Image

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---- configuration from environment variables (no hard-coded values) ----
BUCKET = os.environ.get("BUCKET_NAME", "")
INPUT_PREFIX = os.environ.get("INPUT_PREFIX", "input/")
OUTPUT_PREFIX = os.environ.get("OUTPUT_PREFIX", "output/")
TABLE_NAME = os.environ.get("TABLE_NAME", "")
CONF_THRESHOLD = float(os.environ.get("CONF_THRESHOLD", "0.25"))
MAX_IMAGE_BYTES = int(os.environ.get("MAX_IMAGE_BYTES", str(10 * 1024 * 1024)))
ALLOWED_EXT = (".jpg", ".jpeg", ".png", ".bmp", ".webp")
TASK_ROOT = os.environ.get("LAMBDA_TASK_ROOT", "/var/task")
WARMUP = os.environ.get("WARMUP", "true").lower() == "true"
WARMUP_BUDGET_S = float(os.environ.get("WARMUP_BUDGET_S", "6"))  # keep init under Lambda's 10 s limit

# ---- AWS clients with automatic retries (exponential backoff) ----
_cfg = Config(retries={"max_attempts": 5, "mode": "standard"},
              connect_timeout=5, read_timeout=30)
s3 = boto3.client("s3", config=_cfg)
table = boto3.resource("dynamodb", config=_cfg).Table(TABLE_NAME) if TABLE_NAME else None


def log(level, message, **fields):
    """Structured JSON log line (searchable in CloudWatch Logs Insights)."""
    logger.log(level, json.dumps({"message": message, **fields}, default=str))


# ---- model is loaded ONCE per execution environment and reused on warm starts ----
_t = time.perf_counter()
MODEL = torch.hub.load(os.path.join(TASK_ROOT, "yolov5"), "custom",
                       path=os.path.join(TASK_ROOT, "yolov5s.pt"),
                       source="local")
MODEL.conf = CONF_THRESHOLD
MODEL_LOAD_MS = round((time.perf_counter() - _t) * 1000, 1)

# ---- v2: warm-up inference during init ----
# PyTorch's first forward pass is several times slower than later ones (one-off kernel
# selection and memory allocation). Running one dummy inference here moves that cost
# out of the first user request. It only runs if init is still inside the time budget,
# so the init phase never risks Lambda's 10 s init limit.
WARMUP_MS = 0.0
if WARMUP and (time.perf_counter() - _T_INIT) < WARMUP_BUDGET_S:
    _w = time.perf_counter()
    MODEL(Image.new("RGB", (640, 480)), size=640)
    WARMUP_MS = round((time.perf_counter() - _w) * 1000, 1)
INIT_MS = round((time.perf_counter() - _T_INIT) * 1000, 1)
_cold = True
log(logging.INFO, "model_loaded", model_load_ms=MODEL_LOAD_MS, warmup_ms=WARMUP_MS, init_ms=INIT_MS)


class RequestError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def respond(status, body):
    return {"statusCode": status,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body, default=str)}


def parse_event(event):
    """Return (bucket, key, source) for API Gateway, S3 trigger or direct invoke."""
    if isinstance(event, dict) and event.get("Records"):
        rec = event["Records"][0]["s3"]
        return rec["bucket"]["name"], unquote_plus(rec["object"]["key"]), "s3"
    if isinstance(event, dict) and "body" in event:
        body = event.get("body") or ""
        if event.get("isBase64Encoded"):
            body = base64.b64decode(body).decode("utf-8")
        try:
            payload = json.loads(body) if isinstance(body, str) else body
        except json.JSONDecodeError:
            raise RequestError(400, "Request body must be valid JSON")
        source = "api"
    else:
        payload, source = event, "direct"
    if not isinstance(payload, dict):
        raise RequestError(400, "Request body must be a JSON object")
    return payload.get("bucket") or BUCKET, payload.get("key"), source


def validate(bucket, key):
    if not key or not isinstance(key, str):
        raise RequestError(400, "Missing required field: key")
    if BUCKET and bucket != BUCKET:
        raise RequestError(403, f"Bucket '{bucket}' is not allowed")
    if not key.startswith(INPUT_PREFIX):
        raise RequestError(400, f"key must start with '{INPUT_PREFIX}'")
    if not key.lower().endswith(ALLOWED_EXT):
        raise RequestError(415, "Unsupported file type. Allowed: " + ", ".join(ALLOWED_EXT))


def sniff_format(raw):
    """Identify the image type from its first bytes (magic numbers), not the file name."""
    if raw[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if raw[:2] == b"BM":
        return "bmp"
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return "webp"
    return None


def put_with_retry(bucket, key, data, content_type, attempts=3):
    """Write to S3; retry with backoff on top of botocore retries, log every failure."""
    for i in range(1, attempts + 1):
        try:
            s3.put_object(Bucket=bucket, Key=key, Body=data, ContentType=content_type)
            return
        except ClientError as e:
            log(logging.WARNING, "s3_put_failed", key=key, attempt=i,
                error=e.response["Error"]["Code"])
            if i == attempts:
                raise
            time.sleep(0.2 * 2 ** i)


def handler(event, context):
    global _cold
    cold_start, _cold = _cold, False
    request_id = getattr(context, "aws_request_id", "local")
    t0 = time.perf_counter()

    try:
        bucket, key, source = parse_event(event)
        validate(bucket, key)
        log(logging.INFO, "request_received", request_id=request_id, source=source,
            bucket=bucket, key=key, cold_start=cold_start)

        # 1) read image from S3
        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
        except ClientError as e:
            if e.response["Error"]["Code"] in ("NoSuchKey", "404", "NotFound"):
                raise RequestError(404, f"Image not found: s3://{bucket}/{key}")
            raise
        if obj["ContentLength"] > MAX_IMAGE_BYTES:
            raise RequestError(413, f"Image larger than {MAX_IMAGE_BYTES // (1024 * 1024)} MB")
        raw = obj["Body"].read()
        t_dl = time.perf_counter()
        # v2: reject empty / non-image content BEFORE handing it to Pillow. In v1 an invalid
        # file reached a library hook that tried to pip-install a package at runtime (read-only
        # filesystem) and returned 500 after 3-7 s instead of a fast 415.
        if not raw:
            raise RequestError(415, "Image file is empty")
        image_format = sniff_format(raw)
        if image_format is None:
            raise RequestError(415, "File content is not a JPEG, PNG, BMP or WEBP image")
        try:
            img = Image.open(io.BytesIO(raw)).convert("RGB")
        except Exception:
            raise RequestError(415, "Image could not be decoded (corrupt or truncated file)")

        # 2) YOLOv5 inference
        results = MODEL(img, size=640)
        t_inf = time.perf_counter()
        df = results.pandas().xyxy[0]
        detections = [{
            "label": r["name"],
            "class_id": int(r["class"]),
            "confidence": round(float(r["confidence"]), 4),
            "bbox": {k: round(float(r[k]), 1) for k in ("xmin", "ymin", "xmax", "ymax")},
        } for _, r in df.iterrows()]
        counts = {k: int(v) for k, v in df["name"].value_counts().items()}

        # 3) store results in S3 (JSON + annotated image)
        stem = os.path.splitext(os.path.basename(key))[0]
        json_key = f"{OUTPUT_PREFIX}results/{stem}_{request_id}.json"
        img_key = f"{OUTPUT_PREFIX}annotated/{stem}_{request_id}.jpg"
        result = {
            "request_id": request_id,
            "source": source,
            "input": f"s3://{bucket}/{key}",
            "image_size": {"width": img.width, "height": img.height, "bytes": obj["ContentLength"]},
            "image_format": image_format,
            "model": "yolov5s",
            "version": "v2",
            "conf_threshold": CONF_THRESHOLD,
            "object_count": len(detections),
            "counts": counts,
            "detections": detections,
            "outputs": {"json": f"s3://{bucket}/{json_key}",
                        "annotated_image": f"s3://{bucket}/{img_key}"},
            "cold_start": cold_start,
            "model_load_ms": MODEL_LOAD_MS if cold_start else 0,
            "warmup_ms": WARMUP_MS if cold_start else 0,
            "memory_mb": getattr(context, "memory_limit_in_mb", None),
            "timing_ms": {"s3_read": round((t_dl - t0) * 1000, 1),
                          "inference": round((t_inf - t_dl) * 1000, 1)},
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        put_with_retry(bucket, json_key, json.dumps(result, indent=2).encode(), "application/json")
        buf = io.BytesIO()
        Image.fromarray(results.render()[0]).save(buf, format="JPEG", quality=85)
        put_with_retry(bucket, img_key, buf.getvalue(), "image/jpeg")

        # 4) store a record in DynamoDB (if configured)
        result["dynamodb"] = "skipped"
        if table:
            try:
                item = json.loads(json.dumps({
                    "request_id": request_id, "image_key": key,
                    "object_count": len(detections), "counts": counts,
                    "detections": detections, "result_s3_key": json_key,
                    "inference_ms": result["timing_ms"]["inference"],
                    "cold_start": cold_start, "created_at": result["timestamp"],
                }), parse_float=Decimal)
                table.put_item(Item=item)
                result["dynamodb"] = "written"
            except ClientError as e:
                result["dynamodb"] = "failed"
                log(logging.ERROR, "dynamodb_put_failed", request_id=request_id,
                    error=e.response["Error"]["Code"])

        result["timing_ms"]["total"] = round((time.perf_counter() - t0) * 1000, 1)
        log(logging.INFO, "request_completed", request_id=request_id, key=key,
            object_count=len(detections), cold_start=cold_start, **result["timing_ms"])
        return respond(200, result)

    except RequestError as e:
        log(logging.WARNING, "request_rejected", request_id=request_id,
            status=e.status, error=e.message)
        return respond(e.status, {"error": e.message, "request_id": request_id})
    except Exception:
        logger.exception("unhandled_error request_id=%s", request_id)
        return respond(500, {"error": "Internal error while processing the image",
                             "request_id": request_id})
