# Implementation notes

This walks through what `infra/deploy.sh` does, step by step, and why. If
you just want to run the thing, see the README - this is for when you want
to understand or modify a step.

Everything below targets `us-east-1` and the account you're currently
authenticated as (`aws sts get-caller-identity` to check).

## 1. Turn on Bedrock model invocation logging

Bedrock can log every request/response to CloudWatch Logs and/or S3. We
want both: Logs for quick Insights queries, S3 because CloudWatch Logs has a
256KB per-event limit and long conversations blow past that.

**S3 bucket for the overflow / large payloads:**

```bash
aws s3 mb s3://bedrock-observability-logs-<ACCOUNT_ID> --region us-east-1
```

**Log group:**

```bash
aws logs create-log-group --log-group-name bedrock-observability-invocations --region us-east-1
```

**IAM role Bedrock assumes to write into both of those.** The trust policy
needs the `aws:SourceAccount` / `aws:SourceArn` conditions - without them
this role can be assumed by Bedrock in any account, which AWS will flag:

```bash
aws iam create-role \
  --role-name bedrock-observability-logging \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "bedrock.amazonaws.com"},
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {"aws:SourceAccount": "<ACCOUNT_ID>"},
        "ArnLike": {"aws:SourceArn": "arn:aws:bedrock:us-east-1:<ACCOUNT_ID>:*"}
      }
    }]
  }'

aws iam put-role-policy \
  --role-name bedrock-observability-logging \
  --policy-name bedrock-logging \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        "Resource": "arn:aws:logs:us-east-1:<ACCOUNT_ID>:log-group:bedrock-observability-invocations:*"
      },
      {
        "Effect": "Allow",
        "Action": ["s3:PutObject"],
        "Resource": "arn:aws:s3:::bedrock-observability-logs-<ACCOUNT_ID>/*"
      }
    ]
  }'
```

**Wire it up:**

```bash
aws bedrock put-model-invocation-logging-configuration \
  --region us-east-1 \
  --logging-config '{
    "cloudWatchConfig": {
      "logGroupName": "bedrock-observability-invocations",
      "roleArn": "arn:aws:iam::<ACCOUNT_ID>:role/bedrock-observability-logging",
      "largeDataDeliveryS3Config": {"bucketName": "bedrock-observability-logs-<ACCOUNT_ID>", "keyPrefix": ""}
    },
    "s3Config": {"bucketName": "bedrock-observability-logs-<ACCOUNT_ID>", "keyPrefix": ""},
    "textDataDeliveryEnabled": true,
    "imageDataDeliveryEnabled": true,
    "embeddingDataDeliveryEnabled": true,
    "videoDataDeliveryEnabled": true
  }'
```

This is account+region wide - it applies to every Bedrock call in
`us-east-1` for this account, not just calls from our Lambda.

## 2. Lambda execution role

The traffic-generator Lambda needs three things: permission to call
Bedrock, permission to write its own logs, and permission to push custom
metrics.

```bash
aws iam create-role \
  --role-name bedrock-observability-demo-lambda-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

aws iam put-role-policy \
  --role-name bedrock-observability-demo-lambda-role \
  --policy-name bedrock-observability-demo \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {"Effect": "Allow", "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"], "Resource": "*"},
      {"Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], "Resource": "arn:aws:logs:us-east-1:<ACCOUNT_ID>:*"},
      {"Effect": "Allow", "Action": ["cloudwatch:PutMetricData"], "Resource": "*"}
    ]
  }'
```

IAM roles take a few seconds to propagate - if `lambda create-function`
fails with "role cannot be assumed", just wait ~10s and retry.

## 3. Deploy the Lambda

```bash
cd lambda
zip -j function.zip lambda_function.py

aws lambda create-function \
  --function-name bedrock-observability-demo \
  --runtime python3.12 \
  --role arn:aws:iam::<ACCOUNT_ID>:role/bedrock-observability-demo-lambda-role \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://function.zip \
  --timeout 300 \
  --memory-size 256 \
  --region us-east-1
```

Timeout is 300s because we're doing up to a few dozen sequential streaming
calls per invocation with small sleeps in between - plenty of headroom.
256MB is more than enough; there's no heavy compute here, just network I/O.

To ship code changes after this:

```bash
zip -j function.zip lambda_function.py
aws lambda update-function-code --function-name bedrock-observability-demo --zip-file fileb://function.zip --region us-east-1
```

## 4. Deploy the dashboard

```bash
aws cloudwatch put-dashboard \
  --dashboard-name bedrock-observability-demo-dashboard \
  --dashboard-body file://infra/dashboard.json \
  --region us-east-1
```

`put-dashboard` is idempotent - re-running it after editing `dashboard.json`
just replaces the widget layout in place.

## 5. Generate some traffic

The Lambda takes `num_requests` and an optional `config` override (any of
`environment`, `region`, `model`, `service_name`, `service_version`).

Production-shaped traffic:

```bash
aws lambda invoke --function-name bedrock-observability-demo \
  --payload '{"num_requests": 20, "config": {"environment": "production", "region": "ap-southeast-2"}}' \
  --region us-east-1 /tmp/out.json
python3 -c "import json; print(json.dumps(json.load(open('/tmp/out.json'))['summary'], indent=2))"
```

Staging, for a side-by-side comparison on the dashboard:

```bash
aws lambda invoke --function-name bedrock-observability-demo \
  --payload '{"num_requests": 20, "config": {"environment": "staging", "region": "us-west-2", "service_version": "2.5.0-beta"}}' \
  --region us-east-1 /tmp/out.json
```

A few concurrent bursts if you want to see something other than a flat line
on the throttle widget (unlikely to actually throttle at low volume, but
worth trying if you're demoing rate limits):

```bash
for i in 1 2 3; do
  aws lambda invoke --function-name bedrock-observability-demo \
    --payload '{"num_requests": 15, "config": {"environment": "production"}}' \
    --region us-east-1 /tmp/burst_$i.json &
done
wait
```

## 6. Check it worked

Metrics usually show up within 60-90 seconds. Custom metrics live under
CloudWatch > Metrics > All metrics > `BedrockDemo`. Native ones are
under `AWS/Bedrock`.

Dashboard:
`https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards/dashboard/bedrock-observability-demo-dashboard`

Set the time range to "Last 1 hour" - the default range on a fresh
dashboard is sometimes wider and dilutes the data down to nothing visible.

### Logs Insights queries worth knowing

Recent invocations (log group `bedrock-observability-invocations`):

```
fields @timestamp, modelId, inputTokenCount, outputTokenCount
| sort @timestamp desc
| limit 20
```

Token usage per hour:

```
stats sum(inputTokenCount) as totalIn, sum(outputTokenCount) as totalOut by bin(1h)
```

Lambda-side errors (log group `/aws/lambda/bedrock-observability-demo`):

```
fields @timestamp, @message
| filter @message like /ERROR/
| sort @timestamp desc
| limit 20
```

## Dimensions reference

| Dimension | Example values |
|---|---|
| Environment | production, staging |
| Region | ap-southeast-2, us-west-2 |
| Model | openai.gpt-oss-120b-1:0 |
| ServiceName | ai-tutor-demo |
| ServiceVersion | 2.4.0, 2.5.0-beta |
| Feature | step-hint, solution-explainer, adaptive-questions |
| PromptVersion | v2.1, v1.3, v3.0 |

These come from `SCENARIOS` and `DEFAULT_CONFIG` in `lambda_function.py`.
Add a scenario or override the config in the invoke payload to get new
combinations without touching the dashboard.

## Gotchas we ran into

- The IAM trust policy for the logging role needs the source-account/ARN
  condition, otherwise it's an overly permissive trust relationship that
  security tooling will (rightly) complain about.
- `CostPerRequest` and `CacheSavings` are published as raw USD * 1000
  ("millicents") because CloudWatch charts don't render sub-cent values on
  a y-axis very legibly otherwise.
- About 1% of requests deliberately send an invalid `maxTokens`, which
  botocore rejects client-side before the call even reaches Bedrock, purely
  so the error-rate widget isn't a flat zero line in a demo. Take that out
  (`ERROR_INJECTION_RATE` in `lambda_function.py`) if you don't want
  synthetic errors mixed into real ones.

## Tearing down

```bash
./infra/cleanup.sh
```

Or by hand:

```bash
aws lambda delete-function --function-name bedrock-observability-demo --region us-east-1
aws iam delete-role-policy --role-name bedrock-observability-demo-lambda-role --policy-name bedrock-observability-demo
aws iam delete-role --role-name bedrock-observability-demo-lambda-role
aws cloudwatch delete-dashboards --dashboard-names bedrock-observability-demo-dashboard --region us-east-1
aws bedrock delete-model-invocation-logging-configuration --region us-east-1
aws iam delete-role-policy --role-name bedrock-observability-logging --policy-name bedrock-logging
aws iam delete-role --role-name bedrock-observability-logging
aws logs delete-log-group --log-group-name bedrock-observability-invocations --region us-east-1
aws s3 rb s3://bedrock-observability-logs-<ACCOUNT_ID> --force
```
