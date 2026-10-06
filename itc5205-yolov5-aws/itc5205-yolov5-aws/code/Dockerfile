FROM public.ecr.aws/lambda/python:3.12

# Lambda filesystem is read-only except /tmp; stop YOLOv5 auto-installing packages
ENV YOLOv5_AUTOINSTALL=false \
    YOLOv5_CONFIG_DIR=/tmp \
    YOLO_CONFIG_DIR=/tmp \
    MPLCONFIGDIR=/tmp \
    TORCH_HOME=/tmp

# CPU-only PyTorch keeps the image much smaller than the CUDA build
RUN pip install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cpu

# YOLOv5 dependencies, then swap to headless OpenCV (no libGL in Lambda)
COPY yolov5/requirements.txt /tmp/req.txt
RUN pip install --no-cache-dir -r /tmp/req.txt && \
    pip uninstall -y opencv-python && \
    pip install --no-cache-dir --force-reinstall --no-deps opencv-python-headless

# v2: also stop the ultralytics package from pip-installing at runtime (read-only filesystem).
# Placed after the pip layers so Docker reuses the cached torch/requirements layers.
ENV YOLO_AUTOINSTALL=false

# Code and weights baked into the image (no downloads at runtime)
COPY yolov5/ ${LAMBDA_TASK_ROOT}/yolov5/
COPY yolov5s.pt app.py ${LAMBDA_TASK_ROOT}/

CMD ["app.handler"]
