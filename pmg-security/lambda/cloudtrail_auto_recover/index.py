"""
CloudTrail 자동복구(self-healing) Lambda
----------------------------------------
감사 로그(CloudTrail)를 끄거나 지우는 행위는 공격 은폐의 첫 수순(T1562: Impair Defenses)이므로,
탐지 즉시 원상복구하고 SNS 로 알린다.

- StopLogging : 로깅을 즉시 재가동(start_logging)
- DeleteTrail : 트레일을 '원래 설정대로' 재생성 + 데이터이벤트 재적용 + 로깅 재가동

안전장치
- AUTO_RECOVER=false(기본/드라이런): 복구하지 않고 알림만(오탐/오작동 관찰용).
- 우리 트레일(TRAIL_NAME)만 대상. 다른 트레일 이벤트는 무시.
- UpdateTrail/PutEventSelectors 는 여기서 자동 되돌리지 않음 → 정상적인 Terraform 변경과
  충돌 방지(그 이벤트들은 EventBridge → SNS 로 '알림만' 유지).
"""

import json
import os

import boto3

ct = boto3.client("cloudtrail")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
AUTO_RECOVER = os.environ.get("AUTO_RECOVER", "false").lower() == "true"

# 재생성에 필요한 '원래 설정' (Terraform 이 실제 트레일 속성에서 주입 → 항상 코드와 일치)
TRAIL_NAME = os.environ["TRAIL_NAME"]
S3_BUCKET = os.environ["S3_BUCKET"]
IS_MULTI_REGION = os.environ.get("IS_MULTI_REGION", "true").lower() == "true"
INCLUDE_GLOBAL = os.environ.get("INCLUDE_GLOBAL", "true").lower() == "true"
ENABLE_VALIDATION = os.environ.get("ENABLE_VALIDATION", "true").lower() == "true"
# 데이터 이벤트(audio uploads/) 재적용용. 비어 있으면 데이터이벤트는 재설정하지 않음.
DATA_RESOURCE_ARN = os.environ.get("DATA_RESOURCE_ARN", "")

HANDLED_EVENTS = {"StopLogging", "DeleteTrail"}


def _notify(subject, lines):
    msg = "\n".join(lines)
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=msg)
    print(json.dumps({"sns_subject": subject, "message": msg}))


def _is_our_trail(detail):
    """이벤트가 우리 트레일을 가리키는지 확인(name 이 이름 또는 ARN 둘 다 올 수 있음)."""
    name = (detail.get("requestParameters") or {}).get("name", "")
    if not name:
        return False
    return name == TRAIL_NAME or name.endswith(f":trail/{TRAIL_NAME}")


def _recreate_trail():
    """삭제된 트레일을 원래 설정대로 재생성 → 데이터이벤트 재적용 → 로깅 시작."""
    ct.create_trail(
        Name=TRAIL_NAME,
        S3BucketName=S3_BUCKET,
        IsMultiRegionTrail=IS_MULTI_REGION,
        IncludeGlobalServiceEvents=INCLUDE_GLOBAL,
        EnableLogFileValidation=ENABLE_VALIDATION,
    )
    if DATA_RESOURCE_ARN:
        ct.put_event_selectors(
            TrailName=TRAIL_NAME,
            EventSelectors=[
                {
                    "ReadWriteType": "All",
                    "IncludeManagementEvents": True,
                    "DataResources": [
                        {"Type": "AWS::S3::Object", "Values": [DATA_RESOURCE_ARN]}
                    ],
                }
            ],
        )
    # CreateTrail 은 '정지' 상태로 만들어지므로 로깅을 별도로 켜야 함
    ct.start_logging(Name=TRAIL_NAME)


def handler(event, context):
    detail = event.get("detail", {})
    event_name = detail.get("eventName", "")

    # 복구 대상(끄기/삭제)만 처리. UpdateTrail/PutEventSelectors 등은 알림만(여기선 skip).
    if event_name not in HANDLED_EVENTS:
        print(f"skip: eventName={event_name}")
        return {"status": "skipped", "reason": event_name}

    # 우리 트레일이 아니면 무시(타 트레일 오작동 방지)
    if not _is_our_trail(detail):
        target = (detail.get("requestParameters") or {}).get("name")
        print(f"skip: not our trail (event for {target})")
        return {"status": "skipped", "reason": "other trail"}

    actor = (detail.get("userIdentity") or {}).get("arn", "unknown")
    mode = "AUTO-RECOVER" if AUTO_RECOVER else "DRY-RUN (alert only)"
    result = "no-action"
    error = None

    if AUTO_RECOVER:
        try:
            if event_name == "StopLogging":
                ct.start_logging(Name=TRAIL_NAME)
                result = "logging re-enabled"
            elif event_name == "DeleteTrail":
                _recreate_trail()
                result = "trail recreated + data events re-applied + logging started"
        except Exception as e:  # noqa: BLE001 - 알림에 실패사유 포함
            error = str(e)
            result = "RECOVER FAILED"

    lines = [
        f"[CloudTrail 자동복구] {mode}",
        f"트레일: {TRAIL_NAME}",
        f"이벤트: {event_name}",
        f"수행 주체(actor): {actor}",
        "",
        f"조치: {result}",
    ]
    if error:
        lines += [f"오류: {error}"]
    if not AUTO_RECOVER:
        lines += ["", "※ 드라이런 모드: 자동 복구하지 않음. AUTO_RECOVER=true 로 켜면 자동 복구됩니다."]

    _notify(f"[보안경보] CloudTrail 변조 탐지: {event_name}", lines)
    return {
        "status": "recovered" if AUTO_RECOVER else "alerted",
        "event": event_name,
        "result": result,
    }
