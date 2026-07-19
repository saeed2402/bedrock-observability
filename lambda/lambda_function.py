"""
bedrock-observability-demo

Little test harness for the AI Tutor -> Bedrock integration. Fires a batch of
made-up tutoring requests at the model and pushes custom metrics to
CloudWatch (BedrockDemo namespace) so we can see latency, cost, token
throughput etc. broken down by environment/feature/prompt version.

This is NOT the real tutor service - it's a standalone Lambda we use to
generate realistic traffic for the observability dashboard.
"""

import json
import os
import random
import time

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")
MODEL_ID = os.environ.get("MODEL_ID", "openai.gpt-oss-120b-1:0")

bedrock = boto3.client("bedrock-runtime", region_name=REGION)
cloudwatch = boto3.client("cloudwatch", region_name=REGION)

# $ per 1K tokens, on-demand pricing for openai.gpt-oss-120b on Bedrock (us-east-1)
# https://aws.amazon.com/bedrock/pricing/ - double check these if they look stale
PRICE_INPUT_PER_1K = 0.00396
PRICE_OUTPUT_PER_1K = 0.01584
PRICE_CACHE_READ_PER_1K = 0.00099

DEFAULT_CONFIG = {
    "environment": "production",
    "region": "ap-southeast-2",
    "model": MODEL_ID,
    "service_name": "ai-tutor-demo",
    "service_version": "2.4.0",
}

# A handful of canned tutoring scenarios. Nowhere near everything the real
# tutor handles, just enough variety to get different token counts / latency
# profiles across the three "features" we chart on the dashboard.
SCENARIOS = [
    {
        "feature": "step-hint",
        "prompt_version": "v2.1",
        "system": (
            "You are a maths tutor for Australian high school students. Give a "
            "brief, encouraging hint (2-3 sentences max) to help the student take "
            "the next step. Do not give the full answer."
        ),
        "prompts": [
            "I'm stuck on: Solve 2x + 5 = 13. I got to 2x = 8 but don't know what to do next.",
            "How do I find the area of a triangle with base 6cm and height 4cm?",
            "I need to simplify 3/4 + 2/3 but I don't know how to add fractions with different denominators.",
            "What's the next step to solve: x^2 - 9 = 0?",
            "I'm trying to find the gradient of y = 3x + 2, what do I look at?",
        ],
    },
    {
        "feature": "solution-explainer",
        "prompt_version": "v1.3",
        "system": (
            "You are a maths tutor. Explain the solution step-by-step in plain "
            "English for a Year 9 student. Keep it under 100 words."
        ),
        "prompts": [
            "Explain how to solve: 3(x - 2) = 12",
            "Explain why the angles in a triangle add up to 180 degrees.",
            "Explain how to calculate the mean of: 4, 7, 9, 12, 8",
            "Explain the difference between perimeter and area.",
            "Explain how to convert 0.75 to a fraction.",
        ],
    },
    {
        "feature": "adaptive-questions",
        "prompt_version": "v3.0",
        "system": (
            "You are a maths curriculum expert. Generate one multiple-choice "
            "question (4 options, one correct) appropriate for the given topic "
            "and year level. Format as JSON with keys: question, options (array), "
            "correct_index."
        ),
        "prompts": [
            "Topic: Linear equations, Year 8",
            "Topic: Pythagoras theorem, Year 9",
            "Topic: Probability, Year 7",
            "Topic: Quadratic factorisation, Year 10",
            "Topic: Percentages and discounts, Year 7",
        ],
    },
]

MAX_RETRIES = 2

# Roughly 1 in 100 requests gets a deliberately broken maxTokens so we get
# something other than a flat line on the error-rate widget. Feel free to
# bump this up if you're demoing and don't want to wait around for a real
# throttle.
ERROR_INJECTION_RATE = 0.01


def publish_metrics(metrics, dimensions):
    dims = [{"Name": k, "Value": v} for k, v in dimensions.items()]
    metric_data = [
        {"MetricName": name, "Value": value, "Unit": unit, "Dimensions": dims}
        for name, value, unit in metrics
    ]
    if metric_data:
        cloudwatch.put_metric_data(Namespace="BedrockDemo", MetricData=metric_data)


def call_bedrock(system_prompt, user_prompt, model_id, max_tokens=200):
    """Streams a single Converse call and times out/retries like the real
    tutor service does. Returns a dict of everything we want to chart."""

    start = time.time()
    retries = 0
    timed_out = False

    if random.random() < ERROR_INJECTION_RATE:
        max_tokens = -1  # botocore rejects this client-side (ParamValidationError), just for the demo

    response = None
    failure_reason = None
    for attempt in range(MAX_RETRIES + 1):
        try:
            response = bedrock.converse_stream(
                modelId=model_id,
                messages=[{"role": "user", "content": [{"text": user_prompt}]}],
                system=[{"text": system_prompt}],
                inferenceConfig={"maxTokens": max_tokens, "temperature": 0.7},
            )
            failure_reason = None
            break
        except bedrock.exceptions.ThrottlingException:
            retries += 1
            failure_reason = "throttled"
            time.sleep(1)
        except Exception as e:
            msg = str(e).lower()
            if "timeout" in msg or "timed out" in msg:
                timed_out = True
                retries += 1
                failure_reason = "timeout"
                time.sleep(1)
            else:
                raise

    if failure_reason:
        raise Exception(f"gave up after {MAX_RETRIES + 1} attempts ({failure_reason})")

    output_text = ""
    first_token_at = None
    input_tokens = output_tokens = cache_read_tokens = 0

    for event in response["stream"]:
        if "contentBlockDelta" in event:
            delta = event["contentBlockDelta"]["delta"]
            if "text" in delta:
                output_text += delta["text"]
                if first_token_at is None:
                    first_token_at = time.time()
        elif "metadata" in event:
            usage = event["metadata"].get("usage", {})
            input_tokens = usage.get("inputTokens", 0)
            output_tokens = usage.get("outputTokens", 0)
            cache_read_tokens = usage.get("cacheReadInputTokens", 0)

    end = time.time()
    latency_s = end - start
    ttfvt_ms = int((first_token_at - start) * 1000) if first_token_at else None
    tokens_per_sec = round(output_tokens / latency_s, 1) if latency_s > 0 else 0

    input_cost = (input_tokens / 1000) * PRICE_INPUT_PER_1K
    output_cost = (output_tokens / 1000) * PRICE_OUTPUT_PER_1K
    cache_savings = (cache_read_tokens / 1000) * (PRICE_INPUT_PER_1K - PRICE_CACHE_READ_PER_1K)

    return {
        "output": output_text[:500],
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_read_tokens": cache_read_tokens,
        "latency_ms": int(latency_s * 1000),
        "ttfvt_ms": ttfvt_ms,
        "tokens_per_sec": tokens_per_sec,
        "cost_usd": round(input_cost + output_cost - cache_savings, 6),
        "cache_savings_usd": round(cache_savings, 6),
        "retries": retries,
        "timed_out": timed_out,
    }


def lambda_handler(event, context):
    num_requests = event.get("num_requests", 5)
    config = {**DEFAULT_CONFIG, **event.get("config", {})}
    model_id = config["model"]

    results = []

    for i in range(num_requests):
        scenario = random.choice(SCENARIOS)
        prompt = random.choice(scenario["prompts"])

        dimensions = {
            "Environment": config["environment"],
            "Region": config["region"],
            "Model": model_id,
            "ServiceName": config["service_name"],
            "ServiceVersion": config["service_version"],
            "Feature": scenario["feature"],
            "PromptVersion": scenario["prompt_version"],
        }

        try:
            result = call_bedrock(scenario["system"], prompt, model_id)
            result["prompt"] = prompt
            result["status"] = "success"

            metrics = [
                ("Invocations", 1, "Count"),
                ("Latency", result["latency_ms"], "Milliseconds"),
                ("OutputTokensPerSecond", result["tokens_per_sec"], "Count/Second"),
                ("CostPerRequest", result["cost_usd"] * 1000, "None"),  # millicents, easier to eyeball on a chart
                ("CacheSavings", result["cache_savings_usd"] * 1000, "None"),
                ("RetryCount", result["retries"], "Count"),
                ("TimeoutCount", 1 if result["timed_out"] else 0, "Count"),
                ("InputTokens", result["input_tokens"], "Count"),
                ("OutputTokens", result["output_tokens"], "Count"),
            ]
            if result["ttfvt_ms"] is not None:
                metrics.append(("TimeToFirstVisibleToken", result["ttfvt_ms"], "Milliseconds"))

            publish_metrics(metrics, dimensions)

        except Exception as e:
            print(f"ERROR feature={scenario['feature']} type={type(e).__name__}: {e}")
            result = {
                "prompt": prompt,
                "status": "error",
                "error": str(e),
                "error_type": type(e).__name__,
            }
            publish_metrics([("Errors", 1, "Count")], dimensions)

        results.append(result)

        # small gap between calls so we don't just hammer the endpoint - not
        # strictly necessary but keeps the latency numbers a bit more honest
        if i < num_requests - 1:
            time.sleep(0.3)

    ok = [r for r in results if r["status"] == "success"]
    ttfvt_values = [r["ttfvt_ms"] for r in ok if r.get("ttfvt_ms")]

    summary = {
        "total_requests": num_requests,
        "successful": len(ok),
        "failed": num_requests - len(ok),
        "config": config,
    }
    if ok:
        summary["avg_latency_ms"] = int(sum(r["latency_ms"] for r in ok) / len(ok))
        summary["avg_tokens_per_sec"] = round(sum(r["tokens_per_sec"] for r in ok) / len(ok), 1)
        summary["total_cost_usd"] = round(sum(r["cost_usd"] for r in ok), 6)
        if ttfvt_values:
            summary["avg_ttfvt_ms"] = int(sum(ttfvt_values) / len(ttfvt_values))

    return {"statusCode": 200, "summary": summary, "results": results}
