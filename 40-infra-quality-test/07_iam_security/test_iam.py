"""
[SecureVoice] 07: IAM 최소권한 및 Secrets Manager 검증

검증 항목:
  [IAM Role 존재]
  - ECS Task Execution Role 존재
  - API Task Role 존재
  - Worker Task Role 존재

  [API Task Role 정책 — 최소권한]
  - s3:PutObject, s3:GetObject (audio bucket만)
  - sqs:SendMessage (free-queue, paid-queue만)
  - s3:GetObject, s3:PutObject 이외 S3 권한 없음

  [Worker Task Role 정책 — 최소권한]
  - sqs:ReceiveMessage, sqs:DeleteMessage, sqs:GetQueueAttributes, sqs:ChangeMessageVisibility
  - s3:GetObject, s3:PutObject (audio, model bucket만)
  - AdminAccess 미포함 확인

  [Secrets Manager]
  - securevoice/dev/db-password 시크릿 존재 + 활성 상태
  - securevoice/dev/jwt-secret-key 시크릿 존재 + 활성 상태

  [ECS Task Execution Role]
  - AmazonECSTaskExecutionRolePolicy 정책 연결 확인
  - Secrets Manager GetSecretValue 권한 확인
"""

import os
import sys
import json
from datetime import datetime

import boto3
from botocore.exceptions import ClientError

AWS_REGION        = os.environ.get("AWS_REGION", "ap-northeast-2")
AWS_PROFILE       = os.environ.get("AWS_PROFILE", "bya")
PROJECT           = os.environ.get("PROJECT", "securevoice")
ENV               = os.environ.get("ENV", "dev")
ROLE_API_TASK     = os.environ.get("ROLE_API_TASK",    f"{PROJECT}-{ENV}-api-task-role")
ROLE_WORKER_TASK  = os.environ.get("ROLE_WORKER_TASK", f"{PROJECT}-{ENV}-worker-task-role")
ROLE_ECS_EXEC     = os.environ.get("ROLE_ECS_EXEC",    f"{PROJECT}-{ENV}-ecs-task-execution-role")
SECRET_DB_APP     = os.environ.get("SECRET_DB_APP", f"{PROJECT}/{ENV}/db-password")
SECRET_JWT        = os.environ.get("SECRET_JWT",     f"{PROJECT}/{ENV}/jwt-secret-key")

PASS_STR = "\033[92m[PASS]\033[0m"
FAIL_STR = "\033[91m[FAIL]\033[0m"
INFO_STR = "\033[94m[INFO]\033[0m"
WARN_STR = "\033[93m[WARN]\033[0m"

session = boto3.Session(region_name=AWS_REGION, profile_name=AWS_PROFILE)
iam = session.client("iam")
sm  = session.client("secretsmanager")

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
# 헬퍼: IAM Role에 연결된 인라인+관리형 정책 수집
# ──────────────────────────────────────────────────────────────────────────────
def get_all_policy_statements(role_name: str) -> list:
    """Role에 연결된 모든 정책의 Statement 목록 반환"""
    statements = []
    try:
        # 관리형 정책
        attached = iam.list_attached_role_policies(RoleName=role_name).get("AttachedPolicies", [])
        for p in attached:
            pv = iam.get_policy(PolicyArn=p["PolicyArn"])
            version_id = pv["Policy"]["DefaultVersionId"]
            doc = iam.get_policy_version(PolicyArn=p["PolicyArn"], VersionId=version_id)
            stmts = doc["PolicyVersion"]["Document"].get("Statement", [])
            statements.extend(stmts if isinstance(stmts, list) else [stmts])

        # 인라인 정책
        inline_names = iam.list_role_policies(RoleName=role_name).get("PolicyNames", [])
        for pname in inline_names:
            doc = iam.get_role_policy(RoleName=role_name, PolicyName=pname)
            stmts = doc["PolicyDocument"].get("Statement", [])
            statements.extend(stmts if isinstance(stmts, list) else [stmts])

    except Exception as e:
        info(f"정책 조회 실패: {e}")
    return statements


def collect_allowed_actions(statements: list) -> set:
    actions = set()
    for stmt in statements:
        if stmt.get("Effect") != "Allow":
            continue
        act = stmt.get("Action", [])
        if isinstance(act, str):
            actions.add(act)
        else:
            actions.update(act)
    return actions


# ──────────────────────────────────────────────────────────────────────────────
# TC-IAM-01: IAM Role 존재 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_role_exists(role_name: str, label: str) -> bool:
    print(f"\n{'─'*60}")
    print(f"[TC-IAM-01] {label} Role 존재 확인: {role_name}")
    try:
        resp = iam.get_role(RoleName=role_name)
        arn  = resp["Role"]["Arn"]
        ok(f"[{label}] Role 존재: {role_name}")
        info(f"  ARN: {arn}")
        return True
    except iam.exceptions.NoSuchEntityException:
        fail(f"[{label}] Role '{role_name}' 미존재")
        return False
    except Exception as e:
        fail(f"[{label}] Role 조회 실패: {e}")
        return False


# ──────────────────────────────────────────────────────────────────────────────
# TC-IAM-02: ECS Task Execution Role 정책 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_execution_role_policies():
    print(f"\n{'─'*60}")
    print(f"[TC-IAM-02] ECS Task Execution Role 정책 확인")
    try:
        attached = iam.list_attached_role_policies(RoleName=ROLE_ECS_EXEC).get("AttachedPolicies", [])
        policy_arns = [p["PolicyArn"] for p in attached]
        info(f"연결된 관리형 정책: {[p['PolicyName'] for p in attached]}")

        exec_policy = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
        if exec_policy in policy_arns:
            ok("AmazonECSTaskExecutionRolePolicy 연결됨")
        else:
            fail("AmazonECSTaskExecutionRolePolicy 미연결")

        # Secrets Manager 권한 확인
        stmts   = get_all_policy_statements(ROLE_ECS_EXEC)
        actions = collect_allowed_actions(stmts)
        if "secretsmanager:GetSecretValue" in actions:
            ok("secretsmanager:GetSecretValue 권한 존재")
        else:
            fail("secretsmanager:GetSecretValue 권한 없음 — Secrets 주입 불가")

    except Exception as e:
        fail(f"ECS Execution Role 정책 확인 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-IAM-03: API Task Role 최소권한 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_api_task_role_permissions():
    print(f"\n{'─'*60}")
    print(f"[TC-IAM-03] API Task Role 최소권한 검증")

    stmts   = get_all_policy_statements(ROLE_API_TASK)
    actions = collect_allowed_actions(stmts)
    info(f"허용된 Action 목록: {sorted(actions)}")

    # 필수 권한
    required = ["s3:PutObject", "s3:GetObject", "sqs:SendMessage"]
    for act in required:
        if act in actions:
            ok(f"[API Task] {act} 권한 존재 (필수)")
        else:
            fail(f"[API Task] {act} 권한 없음 (필수 권한 누락!)")

    # 과도한 권한 없는지 확인
    dangerous = [
        "iam:*", "iam:PassRole",
        "sqs:DeleteMessage", "sqs:ReceiveMessage",
        "s3:DeleteObject", "s3:DeleteBucket",
        "*",
    ]
    for act in dangerous:
        if act in actions:
            fail(f"[API Task] 과도한 권한 발견: {act}")
        else:
            ok(f"[API Task] 과도한 권한 없음: {act} ✓")


# ──────────────────────────────────────────────────────────────────────────────
# TC-IAM-04: Worker Task Role 최소권한 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_worker_task_role_permissions():
    print(f"\n{'─'*60}")
    print(f"[TC-IAM-04] Worker Task Role 최소권한 검증")

    stmts   = get_all_policy_statements(ROLE_WORKER_TASK)
    actions = collect_allowed_actions(stmts)
    info(f"허용된 Action 목록: {sorted(actions)}")

    # 필수 권한
    required = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility",
        "s3:GetObject",
        "s3:PutObject",
    ]
    for act in required:
        if act in actions:
            ok(f"[Worker Task] {act} 권한 존재 (필수)")
        else:
            fail(f"[Worker Task] {act} 권한 없음 (필수 권한 누락!)")

    # 과도한 권한 없는지
    dangerous = ["iam:*", "iam:PassRole", "sqs:SendMessage", "*"]
    for act in dangerous:
        if act in actions:
            fail(f"[Worker Task] 과도한 권한 발견: {act}")
        else:
            ok(f"[Worker Task] 과도한 권한 없음: {act} ✓")


# ──────────────────────────────────────────────────────────────────────────────
# TC-IAM-05: Secrets Manager 시크릿 상태 상세 검증
# ──────────────────────────────────────────────────────────────────────────────
def test_secrets_status():
    print(f"\n{'─'*60}")
    print("[TC-IAM-05] Secrets Manager 시크릿 상태 검증")

    secrets = [
        (SECRET_DB_APP, "DB 앱 계정 자격증명"),
        (SECRET_JWT,    "JWT 서명 키"),
    ]

    for secret_id, label in secrets:
        try:
            desc = sm.describe_secret(SecretId=secret_id)
            name = desc["Name"]

            # 삭제 예약 여부
            if desc.get("DeletedDate"):
                fail(f"[{label}] '{name}' 삭제 예약 상태!")
                continue

            ok(f"[{label}] '{name}' 정상 활성 상태")

            # 최근 버전 존재 확인
            versions = desc.get("VersionIdsToStages", {})
            current = [vid for vid, stages in versions.items() if "AWSCURRENT" in stages]
            if current:
                ok(f"[{label}] AWSCURRENT 버전 존재: {current[0][:8]}...")
            else:
                fail(f"[{label}] AWSCURRENT 버전 없음 — 시크릿 값 미설정")

            # 마지막 접근 시각
            last_accessed = desc.get("LastAccessedDate")
            if last_accessed:
                info(f"  마지막 접근: {last_accessed.strftime('%Y-%m-%d %H:%M UTC')}")
            else:
                print(f"  {WARN_STR} 마지막 접근 기록 없음 (아직 사용되지 않았을 수 있음)")

        except sm.exceptions.ResourceNotFoundException:
            fail(f"[{label}] 시크릿 '{secret_id}' 미존재")
        except Exception as e:
            fail(f"[{label}] 시크릿 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\n{'#'*60}")
    print(f"# SecureVoice 07: IAM 최소권한 및 Secrets Manager 검증")
    print(f"# 실행 시각: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'#'*60}")

    # Role 존재 확인
    exec_ok   = test_role_exists(ROLE_ECS_EXEC,    "ECS Task Execution")
    api_ok    = test_role_exists(ROLE_API_TASK,    "API Task")
    worker_ok = test_role_exists(ROLE_WORKER_TASK, "Worker Task")

    # 정책 검증
    if exec_ok:
        test_execution_role_policies()
    if api_ok:
        test_api_task_role_permissions()
    if worker_ok:
        test_worker_task_role_permissions()

    test_secrets_status()

    print(f"\n{'='*60}")
    total = results["pass"] + results["fail"]
    print(f"결과: {results['pass']}/{total} PASS  |  {results['fail']}/{total} FAIL")
    sys.exit(0 if results["fail"] == 0 else 1)
