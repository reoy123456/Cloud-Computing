ITC5205 Assignment 2 - Image Object Identification System on AWS
=================================================================
Student name : [Student Name]
Student ID   : 250014
Institution  : Apex Australia Higher Education

Description
-----------
A serverless object-detection service. A client sends POST /detect to Amazon
API Gateway with an API key and the S3 key of an image. API Gateway validates
the request and invokes an AWS Lambda function packaged as a container image.
The function runs YOLOv5s, writes a JSON result and an annotated image to
Amazon S3, records the detection in Amazon DynamoDB and returns the detected
objects (label, confidence, bounding box) to the client.

Live endpoint : https://lav5va3cge.execute-api.us-east-1.amazonaws.com/prod/detect
Region        : us-east-1
Dataset       : COCO 2017 validation images - https://cocodataset.org/
                (files from http://images.cocodataset.org/val2017/)

Folder structure
----------------
code/
  app.py                Lambda handler (v2): validation, YOLOv5 inference,
                        S3 writes with retry, DynamoDB record, JSON logging
  Dockerfile            Lambda container image (Python 3.12, CPU PyTorch,
                        YOLOv5, headless OpenCV, weights baked in)
deploy/
  build_and_push.sh     Build the image on the EC2 builder and push to ECR
  deploy_lambda.sh      Create/update the Lambda function and its settings
  setup_api_gateway.sh  REST API, request model, POST /detect, key, usage plan
  setup_dynamodb.sh     Table with target-tracking auto scaling
  api_test.sh           Five functional API tests (key passed as an argument)
  perf_test.sh          Dataset upload, batch, memory sweep, cold-start, load
                        and CloudWatch metric tests (writes CSVs)
  iam/                  IAM trust and permission policies (JSON)
  api/                  DetectRequest JSON schema model
  analysis/             make_charts.py - builds the report charts from CSVs

Quick start
-----------
1. Create the S3 bucket and IAM roles using deploy/iam/*.json.
2. On an EC2 instance with Docker:  bash deploy/build_and_push.sh
3. From CloudShell:                 bash deploy/setup_dynamodb.sh
                                    bash deploy/deploy_lambda.sh
                                    bash deploy/setup_api_gateway.sh
4. Upload an image:  aws s3 cp bus.jpg s3://itc5205-yolo-250014/input/bus.jpg
5. Test:             bash deploy/api_test.sh <API_KEY>

The YOLOv5 source (https://github.com/ultralytics/yolov5) and the yolov5s.pt
weights are copied into the build folder by build_and_push.sh; they are not
stored in this repository. No API keys or credentials are stored here.
