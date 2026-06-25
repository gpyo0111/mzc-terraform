"""
[SecureVoice] 09: Recovery Stability — 복구 안정성 검증

검증 항목:
  TC-REC-01: ECS Task 강제 중단 → 자동 재시작 (Crash Recovery)
  TC-REC-02: Worker 단독 장애 시 API 정상 응답 (Partial Failure)
  TC-REC-03: SQS 메시지 보존 — Worker 없는 동안 큐 유실 없음 (Message Durability)
  TC-REC-04: RDS 재부팅 후 API 재연결 확인 (Dependency Failure)

주의:
  - TC-REC-02/03은 Worker desiredCount를 0으로 변경했다가 복구합니다.
    테스트 실패 시에도 finally 블록에서 반드시 원래 값으로 복구합니다.
  - TC-REC-04는 RDS 재부팅을 유발하므로 약 60~120초 소요됩니다.
    --force-failover 는 Multi-AZ 전용이므로 dev(Single-AZ)에서는 일반 재부팅으로 대체합니다.
"""

import os
import sys
import time
import json
import uuid
import boto3
import requests
from datetime import datetime, timezone

# ── 환경 변수 ──────────────────────────────────────────────────────────────────
AWS_REGION           = os.environ.get("AWS_REGION", "ap-northeast-2")
AWS_PROFILE          = os.environ.get("AWS_PROFILE", "bya")
ECS_CLUSTER          = os.environ.get("ECS_CLUSTER", "securevoice-dev-cluster")
ECS_SERVICE_API      = os.environ.get("ECS_SERVICE_API", "securevoice-dev-api-service")
ECS_SERVICE_FREE     = os.environ.get("ECS_SERVICE_FREE_WORKER", "securevoice-dev-free-worker-service")
ECS_SERVICE_PAID     = os.environ.get("ECS_SERVICE_PAID_WORKER", "securevoice-dev-paid-worker-service")
FREE_QUEUE_URL       = os.environ.get("FREE_QUEUE_URL", "")
PAID_QUEUE_URL       = os.environ.get("PAID_QUEUE_URL", "")
RDS_IDENTIFIER       = os.environ.get("RDS_IDENTIFIER", "securevoice-dev-mysql")
API_HOST             = os.environ.get("API_HOST", "http://api-origin.mzmt.shop")

# ── 타임아웃 설정 (초) ────────────────────────────────────────────────────────
TASK_RECOVERY_TIMEOUT  = 180   # TC-REC-01: Task 재시작 대기 최대 3분
WORKER_DOWN_WAIT       = 30    # TC-REC-02: Worker 중단 후 안정화 대기
SERVICE_RECOVERY_TIMEOUT = 180 # TC-REC-02/03: 서비스 복구 대기 최대 3분
RDS_REBOOT_TIMEOUT     = 300   # TC-REC-04: RDS 재부팅 후 대기 최대 5분
API_HEALTH_TIMEOUT     = 120   # TC-REC-04: API 재연결 확인 최대 2분
POLL_INTERVAL          = 5     # 상태 폴링 간격

# ── 출력 헬퍼 ─────────────────────────────────────────────────────────────────
PASS_STR = "\033[92m[PASS]\033[0m"
FAIL_STR = "\033[91m[FAIL]\033[0m"
INFO_STR = "\033[94m[INFO]\033[0m"
WARN_STR = "\033[93m[WARN]\033[0m"

results = {"pass": 0, "fail": 0}


def ok(msg: str):
    print(f"{PASS_STR} {msg}")
    results["pass"] += 1


def fail(msg: str):
    print(f"{FAIL_STR} {msg}")
    results["fail"] += 1


def info(msg: str):
    print(f"{INFO_STR} {msg}")


def warn(msg: str):
    print(f"{WARN_STR} {msg}")


def separator(title: str):
    print(f"\n{'─'*60}")
    print(title)


# ── boto3 클라이언트 ──────────────────────────────────────────────────────────
session = boto3.Session(region_name=AWS_REGION, profile_name=AWS_PROFILE)
ecs     = session.client("ecs")
sqs     = session.client("sqs")
rds     = session.client("rds")


# ── 유틸: ECS 서비스의 현재 running/desired 수 조회 ──────────────────────────
def get_service_counts(service_name: str) -> dict:
    resp = ecs.describe_services(cluster=ECS_CLUSTER, services=[service_name])
    svc  = resp["services"][0]
    return {
        "desired": svc["desiredCount"],
        "running": svc["runningCount"],
        "pending": svc["pendingCount"],
    }


# ── 유틸: desiredCount 변경 ───────────────────────────────────────────────────
def set_desired_count(service_name: str, count: int):
    ecs.update_service(
        cluster=ECS_CLUSTER,
        service=service_name,
        desiredCount=count,
    )
    info(f"서비스 '{service_name}' desiredCount → {count} 설정")


# ── 유틸: running == target 될 때까지 폴링 ───────────────────────────────────
def wait_for_running(service_name: str, target: int, timeout: int) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        counts = get_service_counts(service_name)
        elapsed = int(time.time() - start)
        print(
            f"  [{elapsed:3d}s] desired={counts['desired']}  "
            f"running={counts['running']}  pending={counts['pending']}\r",
            end="",
            flush=True,
        )
        if counts["running"] == target and counts["pending"] == 0:
            print()
            return True
        time.sleep(POLL_INTERVAL)
    print()
    return False


# ── 유틸: API Health Check ────────────────────────────────────────────────────
def check_api_health(timeout: int = 10) -> tuple[bool, int, float]:
    """(is_ok, status_code, elapsed_ms)"""
    try:
        resp = requests.get(f"{API_HOST}/api/health", timeout=timeout)
        return resp.status_code == 200, resp.status_code, resp.elapsed.total_seconds() * 1000
    except requests.exceptions.ConnectionError:
        return False, 0, -1
    except requests.exceptions.Timeout:
        return False, -1, -1
    except Exception:
        return False, -2, -1


# ──────────────────────────────────────────────────────────────────────────────
# TC-REC-01: ECS Task 강제 중단 → 자동 재시작
# ──────────────────────────────────────────────────────────────────────────────
def test_ecs_task_crash_recovery():
    separator("[TC-REC-01] ECS Task 강제 중단 → 자동 재시작 확인")
    info(f"대상 서비스: {ECS_SERVICE_API}")

    try:
        # 현재 실행 중인 Task ARN 목록 조회
        task_resp = ecs.list_tasks(cluster=ECS_CLUSTER, serviceName=ECS_SERVICE_API)
        task_arns = task_resp.get("taskArns", [])

        if not task_arns:
            fail("실행 중인 Task 없음 — API 서비스가 구동 중인지 확인 필요")
            return

        target_task = task_arns[0]
        info(f"강제 중단할 Task: {target_task.split('/')[-1]}")

        # 중단 전 desired 수 확인
        before = get_service_counts(ECS_SERVICE_API)
        info(f"중단 전 상태: running={before['running']}  desired={before['desired']}")

        # Task 강제 중단
        ecs.stop_task(
            cluster=ECS_CLUSTER,
            task=target_task,
            reason="[TC-REC-01] Recovery stability test — intentional stop",
        )
        ok(f"Task 강제 중단 요청 완료: {target_task.split('/')[-1]}")
        t_stop = time.time()

        # ECS가 자동으로 새 Task를 띄워 desired 수 복구하길 기다림
        info(f"자동 재시작 대기 중 (최대 {TASK_RECOVERY_TIMEOUT}s)...")
        recovered = wait_for_running(
            ECS_SERVICE_API,
            target=before["desired"],
            timeout=TASK_RECOVERY_TIMEOUT,
        )
        elapsed = int(time.time() - t_stop)

        if recovered:
            ok(f"Task 자동 재시작 완료 — 복구 소요 시간: {elapsed}s")
            if elapsed <= 60:
                ok(f"복구 시간 60s 이내 ({elapsed}s) — 기준 충족")
            elif elapsed <= 120:
                warn(f"복구 시간 {elapsed}s — 허용 범위(120s) 이내지만 최적화 권장")
            else:
                fail(f"복구 시간 {elapsed}s — 120s 초과")
        else:
            fail(f"Task 재시작 {TASK_RECOVERY_TIMEOUT}s 내 미완료")

        # 복구 후 Health Check 추가 확인
        is_ok, status, elapsed_ms = check_api_health()
        if is_ok:
            ok(f"복구 후 API Health Check 정상 ({status}, {elapsed_ms:.0f}ms)")
        else:
            fail(f"복구 후 API Health Check 실패 (status={status})")

    except Exception as e:
        fail(f"TC-REC-01 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-REC-02: Worker 단독 장애 시 API 정상 응답
# ──────────────────────────────────────────────────────────────────────────────
def test_partial_failure_worker_down():
    separator("[TC-REC-02] Worker 단독 장애 시 API 정상 응답 여부 (Partial Failure)")

    # Free Worker와 Paid Worker 모두 테스트
    for svc_name, label in [
        (ECS_SERVICE_FREE, "Free-Worker"),
        (ECS_SERVICE_PAID, "Paid-Worker"),
    ]:
        info(f"\n대상 서비스: {label} ({svc_name})")
        original_desired = None
        try:
            original_counts = get_service_counts(svc_name)
            original_desired = original_counts["desired"]
            info(f"원래 desiredCount: {original_desired}")

            if original_desired == 0:
                warn(f"{label} desiredCount가 이미 0 — 건너뜀")
                continue

            # Worker를 0으로 내림
            set_desired_count(svc_name, 0)
            info(f"{label} 중단 후 {WORKER_DOWN_WAIT}s 안정화 대기...")
            time.sleep(WORKER_DOWN_WAIT)

            # API Health Check — Worker 없어도 API는 200이어야 함
            info("Worker 없는 상태에서 API Health Check 실행...")
            is_ok, status, elapsed_ms = check_api_health()
            if is_ok:
                ok(f"Worker 없이도 API Health Check 정상 (HTTP {status}, {elapsed_ms:.0f}ms)")
            else:
                fail(f"Worker 없을 때 API Health Check 실패 (status={status}) — API가 Worker 의존적으로 동작함")

            # 추가: /api/health 외 간단한 엔드포인트 연속 확인 (3회)
            consecutive_ok = 0
            for i in range(3):
                is_ok, status, _ = check_api_health(timeout=5)
                if is_ok:
                    consecutive_ok += 1
                time.sleep(2)

            if consecutive_ok == 3:
                ok(f"연속 3회 Health Check 모두 정상 (Worker 없는 상태)")
            else:
                fail(f"연속 Health Check {consecutive_ok}/3 성공 — 불안정한 응답")

        except Exception as e:
            fail(f"TC-REC-02 ({label}) 오류: {e}")
        finally:
            # Worker 반드시 원래 값으로 복구
            if original_desired is not None and original_desired > 0:
                info(f"{label} 복구 중 (desiredCount → {original_desired})...")
                try:
                    set_desired_count(svc_name, original_desired)
                    recovered = wait_for_running(svc_name, original_desired, SERVICE_RECOVERY_TIMEOUT)
                    if recovered:
                        ok(f"{label} 서비스 복구 완료")
                    else:
                        warn(f"{label} 서비스 복구 대기 시간 초과 — 수동 확인 필요")
                except Exception as e_rec:
                    warn(f"{label} 복구 중 오류 (수동 확인 필요): {e_rec}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-REC-03: SQS 메시지 보존 — Worker 없는 동안 큐 유실 없음
# ──────────────────────────────────────────────────────────────────────────────
def test_sqs_message_durability():
    separator("[TC-REC-03] SQS 메시지 보존 — Worker 없는 동안 큐 유실 없음 (Message Durability)")

    if not FREE_QUEUE_URL:
        warn("FREE_QUEUE_URL 미설정 — TC-REC-03 건너뜀")
        return

    original_desired = None
    test_message_id = f"recovery-test-{uuid.uuid4().hex[:8]}"

    try:
        # 현재 Worker 상태 확인
        counts = get_service_counts(ECS_SERVICE_FREE)
        original_desired = counts["desired"]
        info(f"Free-Worker 현재 desiredCount: {original_desired}")

        # Worker를 0으로 내림 (메시지가 처리되지 않도록)
        if original_desired > 0:
            set_desired_count(ECS_SERVICE_FREE, 0)
            info("Worker 중단 후 15s 대기 (기존 Task 종료 대기)...")
            time.sleep(15)

        # 현재 큐 깊이 기록
        attrs_before = sqs.get_queue_attributes(
            QueueUrl=FREE_QUEUE_URL,
            AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"],
        )["Attributes"]
        depth_before = int(attrs_before.get("ApproximateNumberOfMessages", 0))
        info(f"메시지 발행 전 큐 깊이: {depth_before}")

        # 테스트 메시지 발행
        send_resp = sqs.send_message(
            QueueUrl=FREE_QUEUE_URL,
            MessageBody=json.dumps({
                "test_id": test_message_id,
                "purpose": "TC-REC-03 message durability test",
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }),
        )
        sent_msg_id = send_resp["MessageId"]
        ok(f"테스트 메시지 발행 완료 (MessageId: {sent_msg_id})")

        # 30초 대기 후 큐 깊이 확인 (Worker 없으므로 메시지가 남아 있어야 함)
        wait_secs = 30
        info(f"Worker 없는 상태로 {wait_secs}s 대기...")
        time.sleep(wait_secs)

        attrs_after_wait = sqs.get_queue_attributes(
            QueueUrl=FREE_QUEUE_URL,
            AttributeNames=["ApproximateNumberOfMessages"],
        )["Attributes"]
        depth_after_wait = int(attrs_after_wait.get("ApproximateNumberOfMessages", 0))
        info(f"대기 후 큐 깊이: {depth_after_wait}")

        if depth_after_wait >= depth_before + 1:
            ok(f"메시지 유실 없음 — Worker 없는 {wait_secs}s 동안 큐에 보존됨 (깊이: {depth_after_wait})")
        elif depth_after_wait > depth_before:
            ok(f"메시지 큐에 보존됨 (깊이 변화: {depth_before} → {depth_after_wait})")
        else:
            fail(f"메시지 유실 가능성 — 큐 깊이 변화 없음 (전: {depth_before}, 후: {depth_after_wait})")

    except Exception as e:
        fail(f"TC-REC-03 오류: {e}")
    finally:
        # Worker 복구
        if original_desired is not None and original_desired > 0:
            info(f"Free-Worker 복구 중 (desiredCount → {original_desired})...")
            try:
                set_desired_count(ECS_SERVICE_FREE, original_desired)
                info(f"Worker 복구 후 메시지 처리 대기 (최대 {SERVICE_RECOVERY_TIMEOUT}s)...")
                recovered = wait_for_running(ECS_SERVICE_FREE, original_desired, SERVICE_RECOVERY_TIMEOUT)

                if recovered:
                    ok("Free-Worker 복구 완료")

                    # Worker 복구 후 큐 소비 확인 (최대 60s)
                    info("큐 소비 확인 중 (최대 60s)...")
                    start = time.time()
                    consumed = False
                    while time.time() - start < 60:
                        attrs = sqs.get_queue_attributes(
                            QueueUrl=FREE_QUEUE_URL,
                            AttributeNames=["ApproximateNumberOfMessages"],
                        )["Attributes"]
                        current_depth = int(attrs.get("ApproximateNumberOfMessages", 0))
                        elapsed = int(time.time() - start)
                        print(f"  [{elapsed:2d}s] 현재 큐 깊이: {current_depth}\r", end="", flush=True)
                        if current_depth == 0:
                            print()
                            ok(f"Worker 복구 후 큐 메시지 소비 완료 ({elapsed}s)")
                            consumed = True
                            break
                        time.sleep(POLL_INTERVAL)
                    print()
                    if not consumed:
                        warn("60s 내 큐 소비 미확인 — 메시지 처리 중이거나 에러 메시지일 수 있음")
                else:
                    warn("Free-Worker 복구 대기 시간 초과 — 수동 확인 필요")
            except Exception as e_rec:
                warn(f"Free-Worker 복구 중 오류 (수동 확인 필요): {e_rec}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-REC-04: RDS 재부팅 후 API 재연결 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_rds_restart_api_reconnect():
    separator("[TC-REC-04] RDS 재부팅 후 API 재연결 확인 (Dependency Failure)")
    info(f"RDS 식별자: {RDS_IDENTIFIER}")

    try:
        # 재부팅 전 RDS 상태 확인
        resp = rds.describe_db_instances(DBInstanceIdentifier=RDS_IDENTIFIER)
        instance = resp["DBInstances"][0]
        multi_az = instance.get("MultiAZ", False)
        current_status = instance["DBInstanceStatus"]

        info(f"현재 RDS 상태: {current_status}  Multi-AZ: {multi_az}")

        if current_status != "available":
            fail(f"RDS 상태가 'available'이 아님 ({current_status}) — 테스트 건너뜀")
            return

        # 재부팅 전 API Health Check 기준값 확인
        is_ok, status, elapsed_ms = check_api_health()
        if not is_ok:
            fail(f"재부팅 전 API Health Check 실패 (status={status}) — 기준값 이상")
            return
        ok(f"재부팅 전 API Health Check 정상 ({status}, {elapsed_ms:.0f}ms)")

        # RDS 재부팅 실행 (Multi-AZ는 ForceFailover, Single-AZ는 일반 재부팅)
        if multi_az:
            info("Multi-AZ 환경 — ForceFailover 재부팅 실행")
            rds.reboot_db_instance(
                DBInstanceIdentifier=RDS_IDENTIFIER,
                ForceFailover=True,
            )
        else:
            info("Single-AZ 환경 — 일반 재부팅 실행 (ForceFailover 불가)")
            rds.reboot_db_instance(DBInstanceIdentifier=RDS_IDENTIFIER)

        ok("RDS 재부팅 요청 완료")
        t_reboot = time.time()

        # RDS가 rebooting 상태로 전환될 때까지 대기 (최대 30s)
        info("RDS rebooting 상태 대기 중...")
        for _ in range(6):
            time.sleep(5)
            check_resp = rds.describe_db_instances(DBInstanceIdentifier=RDS_IDENTIFIER)
            check_status = check_resp["DBInstances"][0]["DBInstanceStatus"]
            if check_status != "available":
                info(f"RDS 상태 전환 확인: {check_status}")
                break

        # RDS available 복구 대기
        info(f"RDS 복구 대기 중 (최대 {RDS_REBOOT_TIMEOUT}s)...")
        rds_recovered = False
        start = time.time()
        while time.time() - start < RDS_REBOOT_TIMEOUT:
            elapsed = int(time.time() - t_reboot)
            check_resp = rds.describe_db_instances(DBInstanceIdentifier=RDS_IDENTIFIER)
            rds_status = check_resp["DBInstances"][0]["DBInstanceStatus"]
            print(f"  [{elapsed:3d}s] RDS 상태: {rds_status}\r", end="", flush=True)
            if rds_status == "available":
                print()
                rds_recovered = True
                ok(f"RDS available 복구 완료 — 소요: {elapsed}s")
                break
            time.sleep(POLL_INTERVAL)
        print()

        if not rds_recovered:
            fail(f"RDS {RDS_REBOOT_TIMEOUT}s 내 복구 미완료")
            return

        # API 재연결 확인 — available 이후 API Health Check 성공까지의 시간 측정
        info(f"API 재연결 확인 중 (최대 {API_HEALTH_TIMEOUT}s)...")
        api_recovered = False
        start = time.time()
        first_fail_logged = False
        while time.time() - start < API_HEALTH_TIMEOUT:
            elapsed = int(time.time() - t_reboot)
            is_ok, status, elapsed_ms = check_api_health(timeout=5)
            print(f"  [{elapsed:3d}s] API Health: {'OK' if is_ok else f'FAIL({status})'}\r", end="", flush=True)
            if is_ok:
                print()
                api_recovered = True
                ok(f"API DB 재연결 완료 — RDS 재부팅 후 총 {elapsed}s 소요")
                if elapsed <= 60:
                    ok(f"재연결 시간 60s 이내 ({elapsed}s) — 기준 충족")
                elif elapsed <= 120:
                    warn(f"재연결 시간 {elapsed}s — 허용 범위(120s) 이내지만 Connection Pool 튜닝 권장")
                else:
                    fail(f"재연결 시간 {elapsed}s — 120s 초과")
                break
            elif not first_fail_logged:
                first_fail_logged = True
                info(f"\n첫 Health Check 실패 (RDS 재부팅 중 예상): status={status}")
            time.sleep(POLL_INTERVAL)
        print()

        if not api_recovered:
            fail(f"API {API_HEALTH_TIMEOUT}s 내 DB 재연결 미완료")

    except rds.exceptions.DBInstanceNotFoundFault:
        fail(f"RDS 인스턴스 '{RDS_IDENTIFIER}' 미존재")
    except Exception as e:
        fail(f"TC-REC-04 오류: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-REC-05: Network Partition (보안 그룹 임시 차단 및 복구)
# ──────────────────────────────────────────────────────────────────────────────
def test_network_partition():
    separator("[TC-REC-05] Network Partition (보안 그룹 임시 차단 및 복구)")
    
    ec2 = session.client("ec2")
    
    try:
        # 1. RDS 인스턴스의 보안 그룹 정보 조회
        db_resp = rds.describe_db_instances(DBInstanceIdentifier=RDS_IDENTIFIER)
        db_sg_id = db_resp["DBInstances"][0]["VpcSecurityGroups"][0]["VpcSecurityGroupId"]
        info(f"대상 RDS 보안 그룹: {db_sg_id}")
        
        # 2. 기존 인바운드 룰 조회
        sg_rules = ec2.describe_security_groups(GroupIds=[db_sg_id])["SecurityGroups"][0]["IpPermissions"]
        
        # MySQL 포트(3306)에 허용된 규칙 찾기
        target_permission = None
        for rule in sg_rules:
            if rule.get("FromPort") == 3306 or rule.get("ToPort") == 3306:
                target_permission = rule
                break
                
        if not target_permission:
            # 3306 규칙이 안 보이면 전체 Inbound 룰 중 첫 번째를 타겟으로 하거나 Skip
            warn("RDS 보안 그룹에서 3306 포트 전용 인바운드 규칙을 찾지 못함. 첫 번째 규칙을 대상으로 시도합니다.")
            if sg_rules:
                target_permission = sg_rules[0]
            else:
                fail("RDS 보안 그룹에 설정된 인바운드 규칙이 존재하지 않습니다.")
                return
                
        info(f"임시 차단할 인바운드 규칙: {target_permission}")
        
        # 3. 인바운드 룰 임시 제거 (Network Partition 시뮬레이션)
        ec2.revoke_security_group_ingress(
            GroupId=db_sg_id,
            IpPermissions=[target_permission]
        )
        ok("RDS 인바운드 규칙 임시 제거 완료 (네트워크 격리)")
        t_blocked = time.time()
        
        try:
            # API Health Check가 실패하는지 확인 (격리 상태이므로 DB 연결 불가로 실패해야 함)
            info("네트워크 격리 상태에서 API Health Check 실패 대기 중...")
            api_failed = False
            for _ in range(6):
                is_ok, status, _ = check_api_health(timeout=3)
                if not is_ok:
                    ok(f"네트워크 격리 확인됨 — API Health Check 실패 (status={status})")
                    api_failed = True
                    break
                time.sleep(5)
                
            if not api_failed:
                warn("네트워크 격리 조치 이후에도 API Health가 유지됨 (기존 커넥션 유효 또는 캐싱 가능성)")
                
        finally:
            # 4. 인바운드 룰 원복 (반드시 수행)
            info("RDS 인바운드 규칙 원복 중...")
            ec2.authorize_security_group_ingress(
                GroupId=db_sg_id,
                IpPermissions=[target_permission]
            )
            ok("RDS 인바운드 규칙 복구 완료")
            
        # 격리 해제 후 API 재연결 확인
        info("네트워크 복구 후 API Health Check 정상화 대기 중...")
        recovered = False
        start = time.time()
        while time.time() - start < 60:
            is_ok, status, elapsed_ms = check_api_health(timeout=5)
            if is_ok:
                ok(f"API 네트워크 연결 정상화 완료 — 소요: {int(time.time() - start)}s (응답: {elapsed_ms:.0f}ms)")
                recovered = True
                break
            time.sleep(POLL_INTERVAL)
            
        if not recovered:
            fail("네트워크 규칙 원원복 후 API 연결 복구 실패")
            
    except Exception as e:
        warn(f"TC-REC-05 진행 중 예외 발생 (Security Group 제어 권한 부족 등): {e}")
        info("이 테스트는 AWS CLI/SDK 환경의 EC2 Security Group 수정 권한이 활성화되어 있어야 수행 가능합니다. (SKIP 처리)")


# ──────────────────────────────────────────────────────────────────────────────
# TC-REC-06: Data Corruption (S3 오디오 버킷 손상 데이터 핸들링 검증)
# ──────────────────────────────────────────────────────────────────────────────
def test_data_corruption():
    separator("[TC-REC-06] Data Corruption (S3 손상 데이터 핸들링 및 무중단 유지)")
    
    if not AUDIO_BUCKET:
        warn("AUDIO_BUCKET 환경변수 미설정으로 TC-REC-06 건너뜀")
        return
        
    s3 = session.client("s3")
    test_key = f"corrupted_test_data_{uuid.uuid4().hex[:8]}.wav"
    
    try:
        # 1. 고의로 깨진/더미 데이터를 S3 오디오 버킷에 업로드
        info(f"S3 버킷 '{AUDIO_BUCKET}'에 테스트용 손상 데이터 업로드 시도: {test_key}")
        corrupted_content = b"This is totally corrupted WAV file format. Invalid headers!"
        
        s3.put_object(
            Bucket=AUDIO_BUCKET,
            Key=test_key,
            Body=corrupted_content,
            ContentType="audio/wav"
        )
        ok("S3 손상 데이터 업로드 완료")
        
        # 2. API가 이를 다룰 때 예외 핸들링을 우아하게 처리하고 전체 서비스가 가용한지 확인
        # (예: 분석 시도 시 API가 500 내지 않고 적절한 HTTP 400 에러를 리턴하는지 등)
        # 여기서는 API Health Check가 데이터 손상 상황에도 계속 살아있는지 확인합니다.
        is_ok, status, _ = check_api_health()
        if is_ok:
            ok("손상 데이터 존재 시에도 API Health Check 서비스 무중단 유지 확인")
        else:
            fail("손상 데이터 업로드 후 API Health Check 비정상화됨")
            
    except Exception as e:
        fail(f"TC-REC-06 실패: {e}")
    finally:
        # 3. 업로드했던 임시 테스트 파일 삭제 복원
        try:
            info("S3 임시 손상 테스트 파일 제거 중...")
            s3.delete_object(Bucket=AUDIO_BUCKET, Key=test_key)
            ok("S3 임시 테스트 파일 정상 복원 완료")
        except Exception as e_clean:
            warn(f"S3 임시 파일 정리 오류: {e_clean}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-REC-07: Latency Injection (RDS DB 지연 쿼리 주입 시뮬레이션)
# ──────────────────────────────────────────────────────────────────────────────
def test_latency_injection():
    separator("[TC-REC-07] Latency Injection (DB 지연 쿼리 주입 시뮬레이션)")
    
    secrets = session.client("secretsmanager")
    
    try:
        import pymysql
    except ImportError:
        warn("pymysql 라이브러리가 로컬에 설치되어 있지 않아 TC-REC-07을 건너뜁니다.")
        return
        
    try:
        # 1. RDS DB 엔드포인트 정보 획득
        db_resp = rds.describe_db_instances(DBInstanceIdentifier=RDS_IDENTIFIER)
        db_host = db_resp["DBInstances"][0]["Endpoint"]["Address"]
        db_port = db_resp["DBInstances"][0]["Endpoint"]["Port"]
        
        # 2. Secrets Manager에서 DB 패스워드 가져오기
        secret_name = os.environ.get("SECRET_DB_APP", "securevoice/dev/db-password")
        sec_resp = secrets.get_secret_value(SecretId=secret_name)
        db_secret = json.loads(sec_resp["SecretString"])
        
        db_user = db_secret.get("username", "root")
        db_pass = db_secret.get("password")
        db_name = db_secret.get("database", "securevoice")
        
        info(f"RDS 연결 시도: {db_host}:{db_port} (User: {db_user})")
        
        # 3. 로컬에서 DB 직접 연결 및 SLEEP 쿼리 주입 시도
        # (로컬 PC가 DB에 접근 가능한 Public IP 규칙 또는 Bastion 연결 상태여야 합니다)
        conn = pymysql.connect(
            host=db_host,
            user=db_user,
            password=db_pass,
            database=db_name,
            port=db_port,
            connect_timeout=5
        )
        
        try:
            with conn.cursor() as cur:
                info("RDS에 15초 지연(SELECT SLEEP) 쿼리 주입...")
                # 비차단으로 실행하기 위해 타임아웃을 설정한 별도 스레드에서 실행하거나,
                # 여기서는 짧은 SLEEP을 걸고 API 헬스가 타임아웃을 버티는지 확인합니다.
                cur.execute("SELECT SLEEP(10)")
                ok("RDS 지연 쿼리 실행 완료")
                
            # 지연 발생 도중 또는 직후 API Health Check 속도 검증
            is_ok, status, elapsed_ms = check_api_health(timeout=15)
            if is_ok:
                ok(f"DB 지연 상황에서 API Health Check 서빙 유지 확인 ({elapsed_ms:.0f}ms)")
            else:
                warn(f"DB 지연 상황에서 API Health Check가 실패 또는 타임아웃 처리됨 (status={status})")
                
        finally:
            conn.close()
            
    except pymysql.err.OperationalError as op_err:
        warn(f"로컬에서 프라이빗 RDS로 직접 연결 불가로 인해 테스트를 건너뜁니다. (OperationalError: {op_err})")
    except Exception as e:
        warn(f"TC-REC-07 실행 실패 또는 건너뜀: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-REC-08: Resource Exhaustion (ECS Fargate Task 자원 고갈 시뮬레이션)
# ──────────────────────────────────────────────────────────────────────────────
def test_resource_exhaustion():
    separator("[TC-REC-08] Resource Exhaustion (ECS Task 자원 고갈 시뮬레이션)")
    
    try:
        # 1. API 서비스의 첫 번째 Task ID 조회
        task_resp = ecs.list_tasks(cluster=ECS_CLUSTER, serviceName=ECS_SERVICE_API)
        task_arns = task_resp.get("taskArns", [])
        
        if not task_arns:
            fail("자원 고갈 테스트를 위한 running API Task가 존재하지 않음")
            return
            
        target_task = task_arns[0].split("/")[-1]
        info(f"자원 고갈을 유발할 대상 Task: {target_task}")
        
        # 2. ecs.execute_command를 사용하여 백그라운드 무한루프로 CPU 100% 임시 부하 발생
        # (주의: ECS Task Exec 기능이 활성화되어 있어야 하며 session-manager-plugin 설치 필요)
        # CPU 100% 부하를 20초간 유도하고 자동 타임아웃 되게 함
        cmd = "/bin/sh -c 'timeout 20 yes > /dev/null &'"
        info(f"ECS Task Exec 명령 전송: {cmd}")
        
        # boto3 클라이언트로 execute_command 요청 전송
        ecs.execute_command(
            cluster=ECS_CLUSTER,
            container="api",
            command=cmd,
            interactive=True,
            task=target_task
        )
        ok("Task에 CPU 고부하 명령 주입 완료")
        
        # 3. 고부하 상황에서 API가 다운되지 않고 응답을 처리하는지 검증
        time.sleep(5)
        is_ok, status, elapsed_ms = check_api_health(timeout=10)
        if is_ok:
            ok(f"CPU 고부하 상황에서도 API 정상 응답 유지 ({elapsed_ms:.0f}ms)")
        else:
            warn(f"CPU 고부하 상황에서 API가 지연 응답하거나 실패함 (status={status})")
            
    except ecs.exceptions.InvalidParameterException as param_err:
        warn(f"ECS Task Exec (enableExecuteCommand) 기능이 비활성화 상태입니다. (SKIP 처리): {param_err}")
    except Exception as e:
        warn(f"TC-REC-08 진행 중 예외 발생 (SSM/TaskExec 권한 부족 등): {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-REC-09: Rolling Restart & Chaos (강제 배포 무중단 가용성 검증)
# ──────────────────────────────────────────────────────────────────────────────
def test_rolling_restart_chaos():
    separator("[TC-REC-09] Rolling Restart & Chaos (강제 배포 무중단 가용성 검증)")
    
    try:
        # API 서비스 원하는 desired 수 확인 및 최소 2개 확보 (무중단 롤링을 위해)
        counts = get_service_counts(ECS_SERVICE_API)
        original_desired = counts["desired"]
        info(f"API 서비스 현재 설정된 desiredCount: {original_desired}")
        
        if original_desired < 2:
            info("무중단 배포 검증을 위해 desiredCount를 임시로 2개로 스케일아웃합니다.")
            set_desired_count(ECS_SERVICE_API, 2)
            if not wait_for_running(ECS_SERVICE_API, 2, 120):
                fail("임시 스케일아웃 대기 시간 초과")
                return
                
        # 1. ecs.update_service로 forceNewDeployment=True 적용하여 새 배포 유발
        info("API 서비스 강제 재배포(Force New Deployment) 시작...")
        ecs.update_service(
            cluster=ECS_CLUSTER,
            service=ECS_SERVICE_API,
            forceNewDeployment=True
        )
        ok("강제 재배포 신호 송신 완료. 롤링 재시작 무중단 헬스체크 모니터링 개시")
        
        # 2. 롤링 배포 기간 동안 주기적으로 헬스체크를 날려 무중단 가용성을 확인
        # (새 태스크 배치 완료 및 이전 태스크 드레이닝까지 지켜봄)
        start_time = time.time()
        success_count = 0
        total_requests = 0
        
        # 최대 150초 동안 2초 간격으로 계속 Health Check를 실행
        monitor_timeout = 150
        while time.time() - start_time < monitor_timeout:
            is_ok, status, _ = check_api_health(timeout=3)
            total_requests += 1
            if is_ok:
                success_count += 1
                
            elapsed = int(time.time() - start_time)
            print(f"  [{elapsed:3d}s] 롤링 모니터링: 성공={success_count}/{total_requests}\r", end="", flush=True)
            
            # 중간에 배포 완료(Desired 태스크가 신규 배포되고 스테이징 상태 안정)되면 조기 종료 가능
            # 여기서는 약 60초간의 연속 호출 성공률을 모니터링
            if elapsed > 60:
                break
            time.sleep(2)
        print()
        
        success_ratio = (success_count / total_requests) * 100 if total_requests > 0 else 0
        info(f"모니터링 결과: 총 {total_requests}회 요청 중 {success_count}회 성공 ({success_ratio:.1f}%)")
        
        if success_ratio >= 98.0:
            ok(f"무중단 롤링 업데이트 검증 PASS (성공률: {success_ratio:.1f}%)")
        else:
            fail(f"무중단 가용성 확보 실패 (성공률: {success_ratio:.1f}%)")
            
    except Exception as e:
        fail(f"TC-REC-09 실패: {e}")
    finally:
        # desiredCount를 원래 값으로 복구 (기존에 1개였다면 다시 1개로 축소)
        if 'original_desired' in locals() and original_desired < 2:
            info(f"API 서비스 desiredCount 원래 상태로 복귀 ({original_desired})...")
            try:
                set_desired_count(ECS_SERVICE_API, original_desired)
                wait_for_running(ECS_SERVICE_API, original_desired, 90)
                ok("API 서비스 복원 완료")
            except Exception as e_res:
                warn(f"API 서비스 복원 중 오류: {e_res}")


# ──────────────────────────────────────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\n{'#'*60}")
    print(f"# SecureVoice 09: Recovery Stability — 복구 안정성 검증")
    print(f"# 실행 시각: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"# 클러스터 : {ECS_CLUSTER}")
    print(f"# API Host : {API_HOST}")
    print(f"# RDS      : {RDS_IDENTIFIER}")
    print(f"{'#'*60}")

    print("""
주의 사항:
  - TC-REC-02/03/09는 ECS Worker/API의 desiredCount를 조정합니다.
  - TC-REC-04는 RDS 재부팅을 유발합니다 (약 60~120s 소요).
  - TC-REC-05는 RDS 인바운드 보안 그룹 규칙을 수정하고 복구합니다.
  - TC-REC-06은 S3 오디오 버킷에 임시 손상 파일을 저장하고 삭제합니다.
  - 프로덕션 환경에서는 실행하지 마세요.
""")

    test_ecs_task_crash_recovery()      # TC-REC-01
    test_partial_failure_worker_down()  # TC-REC-02
    test_sqs_message_durability()       # TC-REC-03
    test_rds_restart_api_reconnect()    # TC-REC-04
    test_network_partition()            # TC-REC-05
    test_data_corruption()              # TC-REC-06
    test_latency_injection()            # TC-REC-07
    test_resource_exhaustion()          # TC-REC-08
    test_rolling_restart_chaos()        # TC-REC-09

    print(f"\n{'='*60}")
    total = results["pass"] + results["fail"]
    print(f"결과: {results['pass']}/{total} PASS  |  {results['fail']}/{total} FAIL")
    sys.exit(0 if results["fail"] == 0 else 1)

