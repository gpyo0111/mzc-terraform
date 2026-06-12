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


CLUSTER_NAME = os.environ["CLUSTER_NAME"]
PAID_WORKER_SERVICE_NAME = os.environ["PAID_WORKER_SERVICE_NAME"]
FREE_WORKER_SERVICE_NAME = os.environ["FREE_WORKER_SERVICE_NAME"]
PAID_QUEUE_URL = os.environ["PAID_QUEUE_URL"]
FREE_QUEUE_URL = os.environ["FREE_QUEUE_URL"]
PAID_WORKER_LOG_GROUP_NAME = os.environ["PAID_WORKER_LOG_GROUP_NAME"]
FREE_WORKER_LOG_GROUP_NAME = os.environ["FREE_WORKER_LOG_GROUP_NAME"]
SLACK_WEBHOOK_SECRET_NAME = os.environ["SLACK_WEBHOOK_SECRET_NAME"]
RUNBOOK_BASE_URL = os.environ["RUNBOOK_BASE_URL"]


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
        summary = build_summary(message)
        send_slack(summary)

    return {"statusCode": 200}


def build_summary(alarm_message: dict) -> dict:
    alarm_name = alarm_message.get("AlarmName", "unknown")
    new_state = alarm_message.get("NewStateValue", "unknown")
    reason = alarm_message.get("NewStateReason", "")
    region = alarm_message.get("Region", REGION)

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

    queue_processing = get_metric_average(
        namespace="SecureVoice/Worker",
        metric_name="QueueProcessingSecondsByQueue",
        queue_type=queue_type,
    )

    inference_latency = get_metric_average(
        namespace="SecureVoice/Worker",
        metric_name="InferenceLatencySecondsByQueue",
        queue_type=queue_type,
    )

    recent_errors = get_recent_error_logs(log_group_name)

    scaling_activity = get_latest_scaling_activity()

    incident_type, likely_cause, recommended_actions = classify_incident(
        alarm_name=alarm_name,
        metric_name=metric_name,
        queue_type=queue_type,
        ecs_state=ecs_state,
        sqs_state=sqs_state,
        queue_processing=queue_processing,
        inference_latency=inference_latency,
        recent_errors=recent_errors,
    )

    runbook_url = get_runbook_url(alarm_name)

    return {
        "alarm_name": alarm_name,
        "new_state": new_state,
        "reason": reason,
        "region": region,
        "namespace": namespace,
        "metric_name": metric_name,
        "threshold": threshold,
        "queue_type": queue_type,
        "incident_type": incident_type,
        "likely_cause": likely_cause,
        "recommended_actions": recommended_actions,
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
        resp = ecs.describe_services(
            cluster=CLUSTER_NAME,
            services=[service_name],
        )
        svc = resp["services"][0]
        return {
            "service": service_name,
            "desired": svc.get("desiredCount", 0),
            "running": svc.get("runningCount", 0),
            "pending": svc.get("pendingCount", 0),
            "status": svc.get("status", "unknown"),
        }
    except Exception as exc:
        print(f"ECS describe error: {exc}")
        return {
            "service": service_name,
            "desired": "unknown",
            "running": "unknown",
            "pending": "unknown",
            "status": "error",
        }


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
        print(f"SQS get attributes error: {exc}")
        return {
            "visible": "unknown",
            "not_visible": "unknown",
            "oldest_age": "unknown",
        }


def get_metric_average(namespace: str, metric_name: str, queue_type: str) -> dict:
    now = datetime.now(timezone.utc)
    start = now - timedelta(minutes=15)

    try:
        resp = cw.get_metric_statistics(
            Namespace=namespace,
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
            return {
                "metric": metric_name,
                "average": "no-data",
                "maximum": "no-data",
                "sample_count": 0,
            }

        latest = datapoints[-1]
        return {
            "metric": metric_name,
            "average": round(latest.get("Average", 0), 3),
            "maximum": round(latest.get("Maximum", 0), 3),
            "sample_count": latest.get("SampleCount", 0),
        }

    except Exception as exc:
        print(f"CloudWatch metric error {metric_name}: {exc}")
        return {
            "metric": metric_name,
            "average": "error",
            "maximum": "error",
            "sample_count": 0,
        }


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
        print(f"CloudWatch Logs error: {exc}")
        return [f"로그 조회 실패: {exc}"]


def clean_log_message(message: str) -> str:
    message = message.replace("\n", " ").replace("\r", " ")
    if len(message) > 220:
        return message[:220] + "..."
    return message


def get_latest_scaling_activity() -> dict:
    try:
        resp = autoscaling.describe_scaling_activities(
            ServiceNamespace="ecs",
            MaxResults=5,
        )

        activities = resp.get("ScalingActivities", [])
        if not activities:
            return {
                "status": "no-activity",
                "cause": "최근 scaling activity 없음",
            }

        activity = activities[0]
        return {
            "status": activity.get("StatusCode", "unknown"),
            "cause": activity.get("Cause", "unknown"),
        }

    except Exception as exc:
        print(f"Scaling activity error: {exc}")
        return {
            "status": "error",
            "cause": str(exc),
        }


def classify_incident(
    alarm_name: str,
    metric_name: str,
    queue_type: str,
    ecs_state: dict,
    sqs_state: dict,
    queue_processing: dict,
    inference_latency: dict,
    recent_errors: list,
):
    if "queue-visible" in alarm_name:
        incident_type = f"{queue_type} SQS backlog 증가"
        likely_cause = "요청 유입량이 worker 처리량보다 많아 queue backlog가 증가했을 가능성이 높음"
        recommended_actions = [
            "Grafana에서 SQS Visible / Oldest Age 패널 확인",
            "ECS worker desired/running/pending count 확인",
            "worker stopped task 및 최근 ERROR 로그 확인",
            "scale-out 후 backlog 감소 여부 확인",
        ]
        return incident_type, likely_cause, recommended_actions

    if "queue-processing" in alarm_name or metric_name == "QueueProcessingSecondsByQueue":
        incident_type = f"{queue_type} Worker queue processing time 증가"
        likely_cause = "worker가 메시지를 받은 뒤 완료하기까지의 시간이 증가했으며, inference 처리 지연 또는 worker resource pressure 가능성이 있음"
        recommended_actions = [
            "Grafana에서 Queue Processing Time 패널 확인",
            "Inference Latency와 SQS NotVisible 동시 증가 여부 확인",
            "ECS MemoryUtilization 및 worker running count 확인",
            "최근 Worker ERROR 로그 확인",
        ]
        return incident_type, likely_cause, recommended_actions

    if "inference-latency" in alarm_name or metric_name == "InferenceLatencySecondsByQueue":
        incident_type = f"{queue_type} Worker inference latency 증가"
        likely_cause = "queue backlog보다 AI model inference 자체 처리 시간이 증가했을 가능성이 높음"
        recommended_actions = [
            "Grafana에서 Inference Latency 패널 확인",
            "Worker CPU/Memory와 model load 관련 로그 확인",
            "scale-out activity 발생 여부 확인",
            "latency 지속 시 worker task 상태와 최근 ERROR 로그 확인",
        ]
        return incident_type, likely_cause, recommended_actions

    if "memory" in alarm_name:
        incident_type = f"{queue_type} Worker memory pressure"
        likely_cause = "worker memory 사용률이 threshold를 초과했으며 model load, 동시 처리, memory leak 가능성이 있음"
        recommended_actions = [
            "Container Insights에서 worker memory trend 확인",
            "ECS stopped reason 및 OOMKilled 로그 확인",
            "worker task restart 반복 여부 확인",
            "필요 시 task memory 또는 worker concurrency 조정 검토",
        ]
        return incident_type, likely_cause, recommended_actions

    return (
        f"{queue_type} Worker alarm",
        "Alarm 이름과 metric 기준으로 세부 원인 확인 필요",
        [
            "CloudWatch Alarm 상세 확인",
            "Grafana dashboard 확인",
            "ECS/SQS/Worker 로그 확인",
        ],
    )


def get_runbook_url(alarm_name: str) -> str:
    file_name = RUNBOOK_MAP.get(alarm_name, "README.md")
    return f"{RUNBOOK_BASE_URL}/{file_name}"


def get_slack_webhook_url() -> str:
    resp = secrets.get_secret_value(SecretId=SLACK_WEBHOOK_SECRET_NAME)
    return resp["SecretString"]


def send_slack(summary: dict):
    webhook_url = get_slack_webhook_url()

    recent_errors = summary["recent_errors"]
    if not recent_errors:
        error_text = "최근 10분 ERROR 로그 없음"
    else:
        error_text = "\n".join([f"- {line}" for line in recent_errors])

    actions = "\n".join([f"{idx + 1}. {item}" for idx, item in enumerate(summary["recommended_actions"])])

    ecs_state = summary["ecs_state"]
    sqs_state = summary["sqs_state"]
    scaling_activity = summary["scaling_activity"]

    text = f"""
*🚨 SecureVoice AIOps Summary*

*장애 유형*
- {summary["incident_type"]}

*Alarm*
- Name: `{summary["alarm_name"]}`
- State: `{summary["new_state"]}`
- Metric: `{summary["namespace"]}/{summary["metric_name"]}`
- Threshold: `{summary["threshold"]}`

*탐지 사유*
```{summary["reason"]}```

*현재 ECS 상태*
- Service: `{ecs_state["service"]}`
- desired/running/pending: `{ecs_state["desired"]}/{ecs_state["running"]}/{ecs_state["pending"]}`
- status: `{ecs_state["status"]}`

*현재 SQS 상태*
- visible/notVisible/oldestAge: `{sqs_state["visible"]}/{sqs_state["not_visible"]}/{sqs_state["oldest_age"]}s`

*최근 App Metric*
- QueueProcessingSecondsByQueue avg/max: `{summary["queue_processing"]["average"]}/{summary["queue_processing"]["maximum"]}`
- InferenceLatencySecondsByQueue avg/max: `{summary["inference_latency"]["average"]}/{summary["inference_latency"]["maximum"]}`

*최근 Scaling Activity*
- status: `{scaling_activity["status"]}`
- cause: `{scaling_activity["cause"]}`

*최근 Worker ERROR 로그*
{error_text}

*추정 원인*
- {summary["likely_cause"]}

*권장 조치*
{actions}

*Runbook*
{summary["runbook_url"]}
""".strip()

    payload = {"text": text}

    req = urllib.request.Request(
        webhook_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"Slack response: {resp.status}")
    except urllib.error.HTTPError as exc:
        print(f"Slack HTTP error: {exc.code} {exc.read().decode('utf-8')}")
        raise
    except Exception as exc:
        print(f"Slack send error: {exc}")
        raise