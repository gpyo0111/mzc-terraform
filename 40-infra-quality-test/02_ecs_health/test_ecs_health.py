"""
[SecureVoice] 02: ECS Fargate 컨테이너 안정성 검증

검증 항목:
  - ECS 클러스터 ACTIVE 상태
  - api / free-worker / paid-worker 서비스 모두 RUNNING
  - 실행 중 태스크 수 = desiredCount
  - ALB Health Check 경로(/api/health) HTTP 200
  - CloudWatch Log Group 존재 및 최근 로그 스트림 확인
"""

import os
import sys
import time
import boto3
import requests
from datetime import datetime, timezone, timedelta

AWS_REGION         = os.environ.get("AWS_REGION", "ap-northeast-2")
AWS_PROFILE        = os.environ.get("AWS_PROFILE", "bya")
ECS_CLUSTER        = os.environ.get("ECS_CLUSTER", "securevoice-dev-cluster")
ECS_SERVICE_API    = os.environ.get("ECS_SERVICE_API", "securevoice-dev-api-service")
ECS_SERVICE_FREE   = os.environ.get("ECS_SERVICE_FREE_WORKER", "securevoice-dev-free-worker-service")
ECS_SERVICE_PAID   = os.environ.get("ECS_SERVICE_PAID_WORKER", "securevoice-dev-paid-worker-service")
LOG_GROUP_API      = os.environ.get("LOG_GROUP_API", "/ecs/securevoice-dev-api")
LOG_GROUP_FREE     = os.environ.get("LOG_GROUP_FREE_WORKER", "/ecs/securevoice-dev-free-worker")
LOG_GROUP_PAID     = os.environ.get("LOG_GROUP_PAID_WORKER", "/ecs/securevoice-dev-paid-worker")
API_HOST           = os.environ.get("API_HOST", "http://api-origin.mzmt.shop")

PASS_STR = "\033[92m[PASS]\033[0m"
FAIL_STR = "\033[91m[FAIL]\033[0m"
INFO_STR = "\033[94m[INFO]\033[0m"
WARN_STR = "\033[93m[WARN]\033[0m"

session = boto3.Session(region_name=AWS_REGION, profile_name=AWS_PROFILE)
ecs = session.client("ecs")
logs = session.client("logs")

results = {"pass": 0, "fail": 0}


def ok(msg: str):
    print(f"{PASS_STR} {msg}")
    results["pass"] += 1


def fail(msg: str):
    print(f"{FAIL_STR} {msg}")
    results["fail"] += 1


def info(msg: str):
    print(f"{INFO_STR} {msg}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-ECS-01: 클러스터 ACTIVE 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_cluster_active():
    print(f"\n{'─'*60}")
    print("[TC-ECS-01] ECS 클러스터 ACTIVE 상태 확인")
    try:
        resp = ecs.describe_clusters(clusters=[ECS_CLUSTER])
        clusters = resp.get("clusters", [])
        if not clusters:
            fail(f"클러스터 '{ECS_CLUSTER}' 미존재")
            return
        status = clusters[0]["status"]
        if status == "ACTIVE":
            ok(f"클러스터 '{ECS_CLUSTER}' 상태: {status}")
        else:
            fail(f"클러스터 상태 비정상: {status}")
    except Exception as e:
        fail(f"클러스터 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-ECS-02: 서비스별 RUNNING 태스크 수 = desiredCount
# ──────────────────────────────────────────────────────────────────────────────
def test_service_running(service_name: str, label: str):
    print(f"\n{'─'*60}")
    print(f"[TC-ECS-02] {label} 서비스 상태 검증")
    try:
        resp = ecs.describe_services(cluster=ECS_CLUSTER, services=[service_name])
        services = resp.get("services", [])
        if not services:
            fail(f"서비스 '{service_name}' 미존재")
            return

        svc = services[0]
        status       = svc["status"]
        desired      = svc["desiredCount"]
        running      = svc["runningCount"]
        pending      = svc["pendingCount"]

        info(f"status={status}  desired={desired}  running={running}  pending={pending}")

        if status != "ACTIVE":
            fail(f"서비스 status 비정상: {status}")
        elif running == desired and pending == 0:
            ok(f"running({running}) == desired({desired}), pending=0")
        elif running < desired:
            fail(f"running({running}) < desired({desired}) — 태스크 부족")
        else:
            ok(f"running({running}) >= desired({desired}) (스케일아웃 중일 수 있음)")

        # 최근 이벤트 확인
        events = svc.get("events", [])[:3]
        if events:
            info("최근 서비스 이벤트:")
            for ev in events:
                print(f"  {ev['createdAt'].strftime('%H:%M:%S')} | {ev['message'][:100]}")

    except Exception as e:
        fail(f"서비스 '{service_name}' 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-ECS-03: ALB Health Check 엔드포인트 HTTP 200 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_api_health_endpoint():
    print(f"\n{'─'*60}")
    print(f"[TC-ECS-03] API Health Check 엔드포인트 확인: GET {API_HOST}/api/health")
    try:
        resp = requests.get(f"{API_HOST}/api/health", timeout=10)
        if resp.status_code == 200:
            ok(f"HTTP {resp.status_code} — 응답시간: {resp.elapsed.total_seconds()*1000:.0f}ms")
            try:
                body = resp.json()
                info(f"응답 본문: {body}")
            except Exception:
                info(f"응답 본문(text): {resp.text[:100]}")
        else:
            fail(f"HTTP {resp.status_code} (기대값: 200) — 응답: {resp.text[:100]}")
    except requests.exceptions.ConnectionError:
        fail(f"ALB 연결 실패: {API_HOST} — ALB가 ACTIVE 상태인지 확인")
    except requests.exceptions.Timeout:
        fail("요청 타임아웃 (10s 초과)")
    except Exception as e:
        fail(f"Health Check 요청 실패: {str(e).encode('ascii', errors='replace').decode('ascii')}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-ECS-04: CloudWatch Log Group 존재 + 최근 24h 내 로그 스트림 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_log_group(log_group: str, label: str):
    print(f"\n{'─'*60}")
    print(f"[TC-ECS-04] {label} 로그 그룹 확인: {log_group}")
    try:
        resp = logs.describe_log_groups(logGroupNamePrefix=log_group)
        groups = resp.get("logGroups", [])
        matched = [g for g in groups if g["logGroupName"] == log_group]

        if not matched:
            fail(f"로그 그룹 '{log_group}' 미존재")
            return

        group = matched[0]
        retention = group.get("retentionInDays", "무제한")
        ok(f"로그 그룹 존재: {log_group} (보존={retention}일)")

        if isinstance(retention, int) and retention != 14:
            print(f"  {WARN_STR} 보존 기간이 14일이 아님 ({retention}일) — Terraform 설정 확인")

        # 최근 24시간 내 스트림 확인
        cutoff_ms = int((datetime.now(timezone.utc) - timedelta(hours=24)).timestamp() * 1000)
        streams_resp = logs.describe_log_streams(
            logGroupName=log_group,
            orderBy="LastEventTime",
            descending=True,
            limit=3,
        )
        streams = streams_resp.get("logStreams", [])
        recent = [s for s in streams if (s.get("lastEventTimestamp") or 0) >= cutoff_ms]

        if recent:
            ok(f"최근 24h 내 로그 스트림 {len(recent)}개 활성")
            for s in recent:
                ts = datetime.fromtimestamp(s.get("lastEventTimestamp", 0) / 1000, tz=timezone.utc)
                print(f"  스트림: {s['logStreamName']} | 마지막 이벤트: {ts.strftime('%Y-%m-%d %H:%M UTC')}")
        else:
            print(f"  {WARN_STR} 최근 24h 내 로그 없음 — 워커가 유휴 상태일 수 있음")

    except Exception as e:
        fail(f"로그 그룹 '{log_group}' 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\n{'#'*60}")
    print(f"# SecureVoice 02: ECS Fargate 컨테이너 안정성 검증")
    print(f"# 실행 시각: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"# 클러스터: {ECS_CLUSTER}")
    print(f"{'#'*60}")

    test_cluster_active()
    test_service_running(ECS_SERVICE_API,  "API")
    test_service_running(ECS_SERVICE_FREE, "Free-Worker")
    test_service_running(ECS_SERVICE_PAID, "Paid-Worker")
    test_api_health_endpoint()
    test_log_group(LOG_GROUP_API,  "API")
    test_log_group(LOG_GROUP_FREE, "Free-Worker")
    test_log_group(LOG_GROUP_PAID, "Paid-Worker")

    print(f"\n{'='*60}")
    total = results["pass"] + results["fail"]
    print(f"결과: {results['pass']}/{total} PASS  |  {results['fail']}/{total} FAIL")
    sys.exit(0 if results["fail"] == 0 else 1)
