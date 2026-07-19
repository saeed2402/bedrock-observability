# Bedrock Observability

Demo project showing how to monitor an AI application built on Amazon Bedrock
using CloudWatch: latency, cost, token throughput, error/throttle/timeout rates,
and cache hit savings, all broken down by environment, feature, region, and
prompt version.

There's no real backend service here, `lambda/lambda_function.py` is a
standalone Lambda that fires a batch of made-up prompts at Bedrock and
publishes the metrics you'd care about in production. Under the hood, it
simulates an AI tutoring app (a student asking for hints, explanations, and
practice questions). Swap in your own prompts and it works the
same way for any Bedrock-backed feature, the tutoring angle is only there
to give the dashboard something to show.

Note that the lambda function deliberately sends ~1% of requests with an invalid
maxTokens to keep the error-rate widget non-flat.

## What's here

```
lambda/
  lambda_function.py   the traffic generator / Bedrock caller
infra/
  dashboard.json        CloudWatch dashboard definition (13 widgets)
  deploy.sh              creates everything in AWS
  cleanup.sh              tears it all down
IMPLEMENTATION.md      step-by-step walkthrough of what deploy.sh does and why
```

## Architecture

```
Lambda (traffic generator)
    |
    +--> Bedrock converse_stream (openai.gpt-oss-120b-1:0)
    |         |
    |         +--> native AWS/Bedrock metrics (throttles, cache tokens, ...)
    |         +--> invocation logs -> CloudWatch Logs + S3
    |
    +--> CloudWatch custom metrics (BedrockDemo namespace)
              |
              +--> CloudWatch dashboard
```

Region: `us-east-1`. Model: `openai.gpt-oss-120b-1:0`, on-demand.

## Metrics on the dashboard

| Metric | Source |
|---|---|
| Invocations | custom |
| Errors / error type | custom + Logs Insights |
| Timeouts | custom |
| Throttles | native `AWS/Bedrock` |
| Retries | custom |
| Latency | custom |
| Time to first visible token | custom |
| Input / output tokens | custom |
| Cache tokens read/written | native `AWS/Bedrock` |
| Output tokens/sec | custom |
| Cost per request | custom (computed from token counts + published pricing) |
| Cache savings | custom |

Custom metrics carry seven dimensions: `Environment`, `Region`, `Model`,
`ServiceName`, `ServiceVersion`, `Feature`, `PromptVersion`. That's what lets
you slice, e.g., "latency for step-hint in production vs staging" straight
from CloudWatch Metrics without touching the dashboard JSON.

## Running it

```bash
./infra/deploy.sh
```

Then generate some traffic:

```bash
aws lambda invoke --function-name bedrock-observability-demo \
  --payload '{"num_requests": 20, "config": {"environment": "production", "region": "ap-southeast-2"}}' \
  --region us-east-1 /tmp/out.json
```

Give it ~60-90 seconds for metrics to land, then open the dashboard link
`deploy.sh` prints at the end.

Full details, including how to compare environments and query the
invocation logs, are in [IMPLEMENTATION.md](./IMPLEMENTATION.md).

## Cleaning up

```bash
./infra/cleanup.sh
```

Removes the Lambda, dashboard, IAM roles, log group, and the S3 bucket
holding invocation logs.

## Cost

Make sure to execute cleanup.sh to have resources deployed removed and stop incurring cost.

Rough numbers for leaving this running for a month at low traffic volumes:
native Bedrock metrics are free, the ~60 custom metric/dimension
combinations run about $18/month, the dashboard is $3/month, and logs are a
dollar or two depending on volume. Call it $25/month all in - this is a demo,
not something meant to run indefinitely.
