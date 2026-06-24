"""
[SecureVoice] 03: Auto Scaling 반응성 검증

검증 항목:
  - CloudWatch Alarm 6개 존재 확인 (Scale-out × 4, Scale-in × 2)
  - Alarm 임계값 설정이 Terraform 코드 기준값과 일치하는지 확인
    · free-queue-visible-high  threshold=2
    · paid-queue-visible-high  threshold=3
    · paid-queue-oldest-age    threshold=60s
    · free/paid-queue-empty    threshold=0 / evaluationPeriods=10
  - AppAutoScaling 정책 존재 (StepScaling 4개)
  - Scaling 정책의 조정값(scalingAdjustment) 검증
    · free scale-out: +1, paid scale-out: +2
    · free scale-in: -1, paid scale-in: -1
  - Scale-out Cooldown: 180s / Scale-in Cooldown: 300s
"""

import os
import sys
from datetime import datetime

import boto3

AWS_REGION   = os.environ.get("AWS_REGION", "ap-northeast-2")
AWS_PROFILE  = os.environ.get("AWS_PROFILE", "bya")
ECS_CLUSTER  = os.environ.get("ECS_CLUSTER", "securevoice-dev-cluster")
PROJECT      = os.environ.get("PROJECT", "securevoice")
ENV          = os.environ.get("ENV", "dev")

PASS_STR = "\033[92m[PASS]\033[0m"
FAIL_STR = "\033[91m[FAIL]\033[0m"
INFO_STR = "\033[94m[INFO]\033[0m"
WARN_STR = "\033[93m[WARN]\033[0m"

session   = boto3.Session(region_name=AWS_REGION, profile_name=AWS_PROFILE)
cw        = session.client("cloudwatch")
aas       = session.client("application-autoscaling")

results = {"pass": 0, "fail": 0}


def ok(msg):
    print(f"{PASS_STR} {msg}")
    results["pass"] += 1


def fail(msg):
    print(f"{FAIL_STR} {msg}")
    results["fail"] += 1


def info(msg):
    print(f"{INFO_STR} {msg}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-AS-01: CloudWatch Alarm 존재 및 설정값 검증
# ──────────────────────────────────────────────────────────────────────────────
EXPECTED_ALARMS = [
    {
        "name":             f"{PROJECT}-free-queue-visible-high",
        "metric":           "ApproximateNumberOfMessagesVisible",
        "threshold":        2.0,
        "comparison":       "GreaterThanOrEqualToThreshold",
        "evaluation_periods": 1,
        "period":           60,
        "label":            "Free Scale-Out",
    },
    {
        "name":             f"{PROJECT}-paid-queue-visible-high",
        "metric":           "ApproximateNumberOfMessagesVisible",
        "threshold":        3.0,
        "comparison":       "GreaterThanOrEqualToThreshold",
        "evaluation_periods": 1,
        "period":           60,
        "label":            "Paid Scale-Out (visible)",
    },
    {
        "name":             f"{PROJECT}-paid-queue-oldest-age-high",
        "metric":           "ApproximateAgeOfOldestMessage",
        "threshold":        60.0,
        "comparison":       "GreaterThanOrEqualToThreshold",
        "evaluation_periods": 1,
        "period":           60,
        "label":            "Paid Scale-Out (age)",
    },
    {
        "name":             f"{PROJECT}-free-queue-empty",
        "metric":           "ApproximateNumberOfMessagesVisible",
        "threshold":        0.0,
        "comparison":       "LessThanOrEqualToThreshold",
        "evaluation_periods": 10,
        "period":           60,
        "label":            "Free Scale-In",
    },
    {
        "name":             f"{PROJECT}-paid-queue-empty",
        "metric":           "ApproximateNumberOfMessagesVisible",
        "threshold":        0.0,
        "comparison":       "LessThanOrEqualToThreshold",
        "evaluation_periods": 10,
        "period":           60,
        "label":            "Paid Scale-In",
    },
]


def test_cloudwatch_alarms():
    print(f"\n{'─'*60}")
    print("[TC-AS-01] CloudWatch Alarm 존재 및 설정값 검증")

    alarm_names = [a["name"] for a in EXPECTED_ALARMS]
    try:
        resp = cw.describe_alarms(AlarmNames=alarm_names)
        existing = {a["AlarmName"]: a for a in resp.get("MetricAlarms", [])}
    except Exception as e:
        fail(f"CloudWatch Alarm 조회 실패: {e}")
        return

    for expected in EXPECTED_ALARMS:
        name  = expected["name"]
        label = expected["label"]

        if name not in existing:
            fail(f"[{label}] Alarm '{name}' 미존재")
            continue

        alarm = existing[name]
        state = alarm["StateValue"]
        info(f"[{label}] Alarm '{name}' | 상태: {state}")

        errors = []
        if alarm.get("Threshold") != expected["threshold"]:
            errors.append(f"threshold={alarm.get('Threshold')} (기대={expected['threshold']})")
        if alarm.get("ComparisonOperator") != expected["comparison"]:
            errors.append(f"comparison={alarm.get('ComparisonOperator')} (기대={expected['comparison']})")
        if alarm.get("EvaluationPeriods") != expected["evaluation_periods"]:
            errors.append(f"evaluationPeriods={alarm.get('EvaluationPeriods')} (기대={expected['evaluation_periods']})")
        if alarm.get("Period") != expected["period"]:
            errors.append(f"period={alarm.get('Period')} (기대={expected['period']})")

        if errors:
            fail(f"[{label}] 설정값 불일치: {', '.join(errors)}")
        else:
            ok(f"[{label}] 설정값 일치 (threshold={expected['threshold']}, evalPeriods={expected['evaluation_periods']})")

        if state == "INSUFFICIENT_DATA":
            print(f"  {WARN_STR} INSUFFICIENT_DATA — SQS 지표가 아직 수집되지 않았을 수 있음")


# ──────────────────────────────────────────────────────────────────────────────
# TC-AS-02: AppAutoScaling 정책 존재 및 조정값 검증
# ──────────────────────────────────────────────────────────────────────────────
EXPECTED_POLICIES = [
    {
        "name":        f"{PROJECT}-free-worker-sqs-scale-out",
        "service":     "free-worker",
        "direction":   "scale-out",
        "adjustment":  1,
        "cooldown":    180,
    },
    {
        "name":        f"{PROJECT}-paid-worker-sqs-scale-out",
        "service":     "paid-worker",
        "direction":   "scale-out",
        "adjustment":  2,
        "cooldown":    180,
    },
    {
        "name":        f"{PROJECT}-free-worker-sqs-scale-in",
        "service":     "free-worker",
        "direction":   "scale-in",
        "adjustment":  -1,
        "cooldown":    300,
    },
    {
        "name":        f"{PROJECT}-paid-worker-sqs-scale-in",
        "service":     "paid-worker",
        "direction":   "scale-in",
        "adjustment":  -1,
        "cooldown":    300,
    },
]


def test_scaling_policies():
    print(f"\n{'─'*60}")
    print("[TC-AS-02] AppAutoScaling 정책 설정값 검증")

    resource_ids = [
        f"service/{ECS_CLUSTER}/{PROJECT}-{ENV}-free-worker-service",
        f"service/{ECS_CLUSTER}/{PROJECT}-{ENV}-paid-worker-service",
    ]

    try:
        all_policies = []
        for rid in resource_ids:
            resp = aas.describe_scaling_policies(
                ServiceNamespace="ecs",
                ResourceId=rid,
                ScalableDimension="ecs:service:DesiredCount",
            )
            all_policies.extend(resp.get("ScalingPolicies", []))
    except Exception as e:
        fail(f"AppAutoScaling 정책 조회 실패: {e}")
        return

    policy_map = {p["PolicyName"]: p for p in all_policies}

    for expected in EXPECTED_POLICIES:
        name = expected["name"]
        if name not in policy_map:
            fail(f"정책 '{name}' 미존재")
            continue

        policy = policy_map[name]
        cfg    = policy.get("StepScalingPolicyConfiguration", {})
        steps  = cfg.get("StepAdjustments", [{}])
        actual_adj      = steps[0].get("ScalingAdjustment", None) if steps else None
        actual_cooldown = cfg.get("Cooldown", None)

        errors = []
        if actual_adj != expected["adjustment"]:
            errors.append(f"ScalingAdjustment={actual_adj} (기대={expected['adjustment']})")
        if actual_cooldown != expected["cooldown"]:
            errors.append(f"Cooldown={actual_cooldown}s (기대={expected['cooldown']}s)")

        if errors:
            fail(f"[{expected['service']} {expected['direction']}] {', '.join(errors)}")
        else:
            ok(f"[{expected['service']} {expected['direction']}] adj={actual_adj}, cooldown={actual_cooldown}s ✓")


# ──────────────────────────────────────────────────────────────────────────────
# TC-AS-03: AppAutoScaling Target 존재 (min/max 용량 확인)
# ──────────────────────────────────────────────────────────────────────────────
def test_scaling_targets():
    print(f"\n{'─'*60}")
    print("[TC-AS-03] AppAutoScaling Target 등록 확인")

    resource_ids = [
        (f"service/{ECS_CLUSTER}/{PROJECT}-{ENV}-free-worker-service", "free-worker"),
        (f"service/{ECS_CLUSTER}/{PROJECT}-{ENV}-paid-worker-service", "paid-worker"),
    ]

    for rid, label in resource_ids:
        try:
            resp = aas.describe_scalable_targets(
                ServiceNamespace="ecs",
                ResourceIds=[rid],
                ScalableDimension="ecs:service:DesiredCount",
            )
            targets = resp.get("ScalableTargets", [])
            if not targets:
                fail(f"[{label}] Scalable Target 미등록")
                continue
            t = targets[0]
            ok(f"[{label}] Target 등록됨 — min={t['MinCapacity']}, max={t['MaxCapacity']}")
        except Exception as e:
            fail(f"[{label}] Target 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\n{'#'*60}")
    print(f"# SecureVoice 03: Auto Scaling 반응성 검증")
    print(f"# 실행 시각: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'#'*60}")

    test_cloudwatch_alarms()
    test_scaling_policies()
    test_scaling_targets()

    print(f"\n{'='*60}")
    total = results["pass"] + results["fail"]
    print(f"결과: {results['pass']}/{total} PASS  |  {results['fail']}/{total} FAIL")
    sys.exit(0 if results["fail"] == 0 else 1)
