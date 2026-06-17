import json
import os
import urllib.request
import urllib.error
from datetime import datetime, timedelta, timezone

import boto3


REGION = os.environ.get("AWS_REGION_NAME", "ap-northeast-2")

ecs = boto3.client("ecs", region_name=REGION)
sqs = boto3.client("sqs", region_name=REGION)
cw = boto3.client("cloudwatch", region_name=REGION)
logs = boto3.client("logs", region_name=REGION)
secrets = boto3.client("secretsmanager", region_name=REGION)
autoscaling = boto3.client("application-autoscaling", region_name=REGION)
bedrock = boto3.client("bedrock-runtime", region_name=REGION)

CLUSTER_NAME = os.environ["CLUSTER_NAME"]
PAID_WORKER_SERVICE_NAME = os.environ["PAID_WORKER_SERVICE_NAME"]
FREE_WORKER_SERVICE_NAME = os.environ["FREE_WORKER_SERVICE_NAME"]
PAID_QUEUE_URL = os.environ["PAID_QUEUE_URL"]
FREE_QUEUE_URL = os.environ["FREE_QUEUE_URL"]
PAID_WORKER_LOG_GROUP_NAME = os.environ["PAID_WORKER_LOG_GROUP_NAME"]
FREE_WORKER_LOG_GROUP_NAME = os.environ["FREE_WORKER_LOG_GROUP_NAME"]
SLACK_WEBHOOK_SECRET_NAME = os.environ["SLACK_WEBHOOK_SECRET_NAME"]
RUNBOOK_BASE_URL = os.environ["RUNBOOK_BASE_URL"]
BEDROCK_MODEL_ID = os.environ["BEDROCK_MODEL_ID"]

RUNBOOK_MAP = {
    "securevoice-paid-queue-visible-high": "01-sqs-backlog.md",
    "securevoice-paid-queue-processing-high": "02-queue-processing-time-high.md",
    "securevoice-paid-inference-latency-high": "03-inference-latency-high.md",
    "securevoice-paid-worker-memory-high": "04-worker-failure.md",
    "securevoice-free-queue-visible-high": "01-sqs-backlog.md",
    "securevoice-free-queue-processing-high": "02-queue-processing-time-high.md",
    "securevoice-free-inference-latency-high": "03-inference-latency-high.md",
    "securevoice-free-worker-memory-high": "04-worker-failure.md",
}


def lambda_handler(event, context):
    print(json.dumps(event, ensure_ascii=False))

    for record in event.get("Records", []):
        message = json.loads(record["Sns"]["Message"])
        context_data = build_context(message)

        try:
            ai_text = generate_bedrock_summary(context_data)
            send_slack(ai_text)
        except Exception as exc:
            print(f"Bedrock summary failed. fallback to rule-based summary: {exc}")
            fallback_text = build_fallback_summary(context_data)
            send_slack(fallback_text)

    return {"statusCode": 200}


def build_context(alarm_message: dict) -> dict:
    alarm_name = alarm_message.get("AlarmName", "unknown")
    new_state = alarm_message.get("NewStateValue", "unknown")
    reason = alarm_message.get("NewStateReason", "")

    trigger = alarm_message.get("Trigger", {})
    metric_name = trigger.get("MetricName", "unknown")
    namespace = trigger.get("Namespace", "unknown")
    threshold = trigger.get("Threshold", "unknown")

    queue_type = infer_queue_type(alarm_name, trigger)
    service_name = PAID_WORKER_SERVICE_NAME if queue_type == "paid" else FREE_WORKER_SERVICE_NAME
    queue_url = PAID_QUEUE_URL if queue_type == "paid" else FREE_QUEUE_URL
    log_group_name = PAID_WORKER_LOG_GROUP_NAME if queue_type == "paid" else FREE_WORKER_LOG_GROUP_NAME

    ecs_state = get_ecs_service_state(service_name)
    sqs_state = get_sqs_state(queue_url)
    queue_processing = get_metric_average("QueueProcessingSecondsByQueue", queue_type)
    inference_latency = get_metric_average("InferenceLatencySecondsByQueue", queue_type)
    recent_errors = get_recent_error_logs(log_group_name)
    scaling_activity = get_latest_scaling_activity()
    runbook_url = get_runbook_url(alarm_name)

    return {
        "alarm_name": alarm_name,
        "new_state": new_state,
        "reason": reason,
        "namespace": namespace,
        "metric_name": metric_name,
        "threshold": threshold,
        "queue_type": queue_type,
        "ecs_state": ecs_state,
        "sqs_state": sqs_state,
        "queue_processing": queue_processing,
        "inference_latency": inference_latency,
        "recent_errors": recent_errors,
        "scaling_activity": scaling_activity,
        "runbook_url": runbook_url,
    }


def infer_queue_type(alarm_name: str, trigger: dict) -> str:
    if "paid" in alarm_name:
        return "paid"
    if "free" in alarm_name:
        return "free"

    for dim in trigger.get("Dimensions", []):
        if dim.get("name") == "QueueType" or dim.get("Name") == "QueueType":
            return dim.get("value") or dim.get("Value") or "paid"

    return "paid"


def get_ecs_service_state(service_name: str) -> dict:
    try:
        resp = ecs.describe_services(cluster=CLUSTER_NAME, services=[service_name])
        svc = resp["services"][0]
        return {
            "service": service_name,
            "desired": svc.get("desiredCount", 0),
            "running": svc.get("runningCount", 0),
            "pending": svc.get("pendingCount", 0),
            "status": svc.get("status", "unknown"),
        }
    except Exception as exc:
        return {"service": service_name, "desired": "unknown", "running": "unknown", "pending": "unknown", "status": f"error: {exc}"}


def get_sqs_state(queue_url: str) -> dict:
    try:
        resp = sqs.get_queue_attributes(
            QueueUrl=queue_url,
            AttributeNames=[
                "ApproximateNumberOfMessages",
                "ApproximateNumberOfMessagesNotVisible",
                "ApproximateAgeOfOldestMessage",
            ],
        )
        attrs = resp.get("Attributes", {})
        return {
            "visible": attrs.get("ApproximateNumberOfMessages", "unknown"),
            "not_visible": attrs.get("ApproximateNumberOfMessagesNotVisible", "unknown"),
            "oldest_age": attrs.get("ApproximateAgeOfOldestMessage", "unknown"),
        }
    except Exception as exc:
        return {"visible": "unknown", "not_visible": "unknown", "oldest_age": f"error: {exc}"}


def get_metric_average(metric_name: str, queue_type: str) -> dict:
    now = datetime.now(timezone.utc)
    start = now - timedelta(minutes=15)

    try:
        resp = cw.get_metric_statistics(
            Namespace="SecureVoice/Worker",
            MetricName=metric_name,
            Dimensions=[
                {"Name": "Environment", "Value": "prod"},
                {"Name": "QueueType", "Value": queue_type},
            ],
            StartTime=start,
            EndTime=now,
            Period=60,
            Statistics=["Average", "Maximum", "SampleCount"],
        )
        datapoints = sorted(resp.get("Datapoints", []), key=lambda x: x["Timestamp"])
        if not datapoints:
            return {"metric": metric_name, "average": "no-data", "maximum": "no-data", "sample_count": 0}

        latest = datapoints[-1]
        return {
            "metric": metric_name,
            "average": round(latest.get("Average", 0), 3),
            "maximum": round(latest.get("Maximum", 0), 3),
            "sample_count": latest.get("SampleCount", 0),
        }
    except Exception as exc:
        return {"metric": metric_name, "average": "error", "maximum": str(exc), "sample_count": 0}


def get_recent_error_logs(log_group_name: str) -> list:
    end_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    start_ms = int((datetime.now(timezone.utc) - timedelta(minutes=10)).timestamp() * 1000)

    try:
        resp = logs.filter_log_events(
            logGroupName=log_group_name,
            startTime=start_ms,
            endTime=end_ms,
            filterPattern='ERROR ?Exception ?Traceback ?"Access denied" ?OOM ?Killed ?FAILED ?timeout',
            limit=5,
        )
        events = resp.get("events", [])
        return [clean_log_message(e.get("message", "")) for e in events[:5]]
    except Exception as exc:
        return [f"로그 조회 실패: {exc}"]


def clean_log_message(message: str) -> str:
    message = message.replace("\n", " ").replace("\r", " ")
    if len(message) > 300:
        return message[:300] + "..."
    return message


def get_latest_scaling_activity() -> dict:
    try:
        resp = autoscaling.describe_scaling_activities(ServiceNamespace="ecs", MaxResults=5)
        activities = resp.get("ScalingActivities", [])
        if not activities:
            return {"status": "no-activity", "cause": "최근 scaling activity 없음"}

        activity = activities[0]
        return {
            "status": activity.get("StatusCode", "unknown"),
            "cause": activity.get("Cause", "unknown"),
        }
    except Exception as exc:
        return {"status": "error", "cause": str(exc)}


def get_runbook_url(alarm_name: str) -> str:
    file_name = RUNBOOK_MAP.get(alarm_name, "README.md")
    return f"{RUNBOOK_BASE_URL}/{file_name}"


def generate_bedrock_summary(context_data: dict) -> str:
    prompt = f"""
너는 AWS ECS 기반 AI inference 서비스의 AIOps 운영 보조자다.
아래 장애 이벤트와 운영 지표를 기반으로 Slack에 보낼 한국어 장애 요약을 작성하라.

출력 형식:
*SecureVoice AI Summary*
*요약:* 한 문장
*영향:* 한 문장
*근거:* 한 문장
*조치:* 한 문장

조건:
- Slack mrkdwn 형식 사용
- 굵게는 * 하나만 사용
- ** 사용 금지
- Runbook 줄은 작성하지 말 것
- 관측된 사실과 추정 원인을 구분
- 테스트 경보면 테스트 경보라고 명시

장애 컨텍스트:
{json.dumps(context_data, ensure_ascii=False, default=str)}
""".strip()

    response = bedrock.converse(
        modelId=BEDROCK_MODEL_ID,
        messages=[
            {
                "role": "user",
                "content": [{"text": prompt}],
            }
        ],
        inferenceConfig={
            "maxTokens": 300,
            "temperature": 0.1,
            "topP": 0.8,
        },
    )

    text = response["output"]["message"]["content"][0]["text"]
    return normalize_slack_summary(text, context_data["runbook_url"])

def normalize_slack_summary(text: str, runbook_url: str) -> str:
    text = text.replace("**", "*").strip()

    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if "Runbook" in stripped or "런북" in stripped:
            continue
        lines.append(stripped)

    lines.append(f"*Runbook:* <{runbook_url}|조치 가이드>")
    return "\n".join(lines)

def build_fallback_summary(context_data: dict) -> str:
    ecs_state = context_data["ecs_state"]
    sqs_state = context_data["sqs_state"]
    errors = context_data["recent_errors"]
    error_text = "최근 10분 ERROR 로그 없음" if not errors else "\n".join([f"- {e}" for e in errors])

    return f"""
*SecureVoice AI Summary*
- Bedrock 호출 실패로 Rule-based fallback 요약을 전송합니다.
- Alarm: `{context_data["alarm_name"]}`
- State: `{context_data["new_state"]}`
- Metric: `{context_data["namespace"]}/{context_data["metric_name"]}`
- ECS desired/running/pending: `{ecs_state["desired"]}/{ecs_state["running"]}/{ecs_state["pending"]}`
- SQS visible/notVisible/oldestAge: `{sqs_state["visible"]}/{sqs_state["not_visible"]}/{sqs_state["oldest_age"]}s`
- QueueProcessing avg/max: `{context_data["queue_processing"]["average"]}/{context_data["queue_processing"]["maximum"]}`
- InferenceLatency avg/max: `{context_data["inference_latency"]["average"]}/{context_data["inference_latency"]["maximum"]}`
- 최근 ERROR 로그: {error_text}
- Runbook: <{context_data["runbook_url"]}|조치 가이드>
""".strip()


def get_slack_webhook_url() -> str:
    resp = secrets.get_secret_value(SecretId=SLACK_WEBHOOK_SECRET_NAME)
    return resp["SecretString"]


def send_slack(text: str):
    webhook_url = get_slack_webhook_url()
    payload = {"text": text}

    req = urllib.request.Request(
        webhook_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=10) as resp:
        print(f"Slack response: {resp.status}")