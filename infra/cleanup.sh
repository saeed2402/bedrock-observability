#!/usr/bin/env bash
#
# Tears down everything deploy.sh created. Run this when you're done with
# the demo - the S3 bucket + logging role are the only parts that cost
# anything meaningful to leave running.

set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

BUCKET="bedrock-observability-logs-${ACCOUNT_ID}"
LOG_GROUP="bedrock-observability-invocations"
LOGGING_ROLE="bedrock-observability-logging"
LAMBDA_ROLE="bedrock-observability-demo-lambda-role"
FUNCTION_NAME="bedrock-observability-demo"
DASHBOARD_NAME="bedrock-observability-demo-dashboard"

echo "==> Deleting dashboard"
aws cloudwatch delete-dashboards --dashboard-names "$DASHBOARD_NAME" --region "$REGION" 2>/dev/null || true

echo "==> Deleting Lambda function"
aws lambda delete-function --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null || true

echo "==> Deleting Lambda execution role"
aws iam delete-role-policy --role-name "$LAMBDA_ROLE" --policy-name bedrock-observability-demo 2>/dev/null || true
aws iam delete-role --role-name "$LAMBDA_ROLE" 2>/dev/null || true

echo "==> Turning off Bedrock invocation logging"
aws bedrock delete-model-invocation-logging-configuration --region "$REGION" 2>/dev/null || true

echo "==> Deleting logging role, log group, and S3 bucket"
aws iam delete-role-policy --role-name "$LOGGING_ROLE" --policy-name bedrock-logging 2>/dev/null || true
aws iam delete-role --role-name "$LOGGING_ROLE" 2>/dev/null || true
aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$REGION" 2>/dev/null || true
aws s3 rm "s3://${BUCKET}" --recursive 2>/dev/null || true
aws s3 rb "s3://${BUCKET}" 2>/dev/null || true

echo "==> Done"
