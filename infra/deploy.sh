#!/usr/bin/env bash
#
# Spins up everything needed for the Bedrock observability demo:
#   - S3 bucket + IAM role for Bedrock model invocation logging
#   - CloudWatch log group the logs land in
#   - Lambda function that generates traffic and publishes custom metrics
#   - the CloudWatch dashboard
#
# Safe to re-run - most steps just no-op or update in place if the resource
# already exists. Requires the AWS CLI configured with an account that has
# Bedrock access in us-east-1.

set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

BUCKET="bedrock-observability-logs-${ACCOUNT_ID}"
LOG_GROUP="bedrock-observability-invocations"
LOGGING_ROLE="bedrock-observability-logging"
LAMBDA_ROLE="bedrock-observability-demo-lambda-role"
FUNCTION_NAME="bedrock-observability-demo"
DASHBOARD_NAME="bedrock-observability-demo-dashboard"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==> Account: ${ACCOUNT_ID}, region: ${REGION}"

# ---------------------------------------------------------------------------
# 1. Bedrock invocation logging (S3 bucket, IAM role, log group)
# ---------------------------------------------------------------------------

if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "==> S3 bucket ${BUCKET} already exists, skipping create"
else
  echo "==> Creating S3 bucket ${BUCKET}"
  aws s3 mb "s3://${BUCKET}" --region "$REGION"
fi

if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$REGION" \
    --query "logGroups[?logGroupName=='${LOG_GROUP}']" --output text | grep -q "$LOG_GROUP"; then
  echo "==> Log group ${LOG_GROUP} already exists, skipping create"
else
  echo "==> Creating log group ${LOG_GROUP}"
  aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION"
fi

if aws iam get-role --role-name "$LOGGING_ROLE" >/dev/null 2>&1; then
  echo "==> IAM role ${LOGGING_ROLE} already exists, skipping create"
else
  echo "==> Creating IAM role ${LOGGING_ROLE} for Bedrock logging"
  aws iam create-role \
    --role-name "$LOGGING_ROLE" \
    --assume-role-policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "bedrock.amazonaws.com"},
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {"aws:SourceAccount": "${ACCOUNT_ID}"},
      "ArnLike": {"aws:SourceArn": "arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:*"}
    }
  }]
}
EOF
)"
fi

aws iam put-role-policy \
  --role-name "$LOGGING_ROLE" \
  --policy-name bedrock-logging \
  --policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    }
  ]
}
EOF
)"

echo "==> Pointing Bedrock model invocation logging at the new bucket/log group"
# give IAM a moment to propagate the role + policy before Bedrock validates them
sleep 10
aws bedrock put-model-invocation-logging-configuration \
  --region "$REGION" \
  --logging-config "$(cat <<EOF
{
  "cloudWatchConfig": {
    "logGroupName": "${LOG_GROUP}",
    "roleArn": "arn:aws:iam::${ACCOUNT_ID}:role/${LOGGING_ROLE}",
    "largeDataDeliveryS3Config": {"bucketName": "${BUCKET}", "keyPrefix": ""}
  },
  "s3Config": {"bucketName": "${BUCKET}", "keyPrefix": ""},
  "textDataDeliveryEnabled": true,
  "imageDataDeliveryEnabled": true,
  "embeddingDataDeliveryEnabled": true,
  "videoDataDeliveryEnabled": true
}
EOF
)"

# ---------------------------------------------------------------------------
# 2. Lambda execution role
# ---------------------------------------------------------------------------

if aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  echo "==> IAM role ${LAMBDA_ROLE} already exists, skipping create"
else
  echo "==> Creating IAM role ${LAMBDA_ROLE} for the Lambda function"
  aws iam create-role \
    --role-name "$LAMBDA_ROLE" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }'
  sleep 10
fi

aws iam put-role-policy \
  --role-name "$LAMBDA_ROLE" \
  --policy-name bedrock-observability-demo \
  --policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:*"
    },
    {
      "Effect": "Allow",
      "Action": ["cloudwatch:PutMetricData"],
      "Resource": "*"
    }
  ]
}
EOF
)"

# ---------------------------------------------------------------------------
# 3. Lambda function
# ---------------------------------------------------------------------------

echo "==> Zipping lambda_function.py"
rm -f "${SCRIPT_DIR}/../lambda/function.zip"
(cd "${REPO_ROOT}/lambda" && zip -j function.zip lambda_function.py)

if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "==> Function ${FUNCTION_NAME} exists, updating code"
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://${REPO_ROOT}/lambda/function.zip" \
    --region "$REGION" >/dev/null
else
  echo "==> Creating function ${FUNCTION_NAME}"
  # role was likely just created above, give it a bit longer to propagate
  sleep 10
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --role "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://${REPO_ROOT}/lambda/function.zip" \
    --timeout 300 \
    --memory-size 256 \
    --region "$REGION" >/dev/null
fi

# ---------------------------------------------------------------------------
# 4. Dashboard
# ---------------------------------------------------------------------------

echo "==> Publishing dashboard ${DASHBOARD_NAME}"
aws cloudwatch put-dashboard \
  --dashboard-name "$DASHBOARD_NAME" \
  --dashboard-body "file://${REPO_ROOT}/infra/dashboard.json" \
  --region "$REGION"

echo "==> Done. Dashboard:"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards/dashboard/${DASHBOARD_NAME}"
