"""
[SecureVoice] 04: RDS / RDS Proxy 연결성 검증

검증 항목:
  - RDS 인스턴스 상태 AVAILABLE
  - Multi-AZ 활성화 확인 (multi_az = true)
  - 자동 백업 보존 기간 7일 확인
  - 스토리지 암호화(storage_encrypted) 활성화
  - Deletion Protection 활성화
  - 퍼블릭 접근 차단 (publicly_accessible = false)
  - 자동 소수 버전 업그레이드 비활성화 (auto_minor_version_upgrade = false)
  - Secrets Manager에서 DB 앱 계정 자격증명 시크릿 존재 확인
  - RDS Proxy 상태 AVAILABLE 확인
"""

import os
import sys
from datetime import datetime

import boto3

AWS_REGION      = os.environ.get("AWS_REGION", "ap-northeast-2")
AWS_PROFILE     = os.environ.get("AWS_PROFILE", "bya")
RDS_IDENTIFIER  = os.environ.get("RDS_IDENTIFIER", "securevoice-dev-mysql")
SECRET_DB_APP   = os.environ.get("SECRET_DB_APP", "securevoice/dev/db-password")
SECRET_JWT      = os.environ.get("SECRET_JWT", "securevoice/dev/jwt-secret-key")
PROJECT         = os.environ.get("PROJECT", "securevoice")
ENV             = os.environ.get("ENV", "dev")

PASS_STR = "\033[92m[PASS]\033[0m"
FAIL_STR = "\033[91m[FAIL]\033[0m"
INFO_STR = "\033[94m[INFO]\033[0m"
WARN_STR = "\033[93m[WARN]\033[0m"

session = boto3.Session(region_name=AWS_REGION, profile_name=AWS_PROFILE)
rds     = session.client("rds")
sm      = session.client("secretsmanager")

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
# TC-RDS-01: RDS 인스턴스 기본 설정 검증
# ──────────────────────────────────────────────────────────────────────────────
def test_rds_instance():
    print(f"\n{'─'*60}")
    print(f"[TC-RDS-01] RDS 인스턴스 설정 검증: {RDS_IDENTIFIER}")
    try:
        resp = rds.describe_db_instances(DBInstanceIdentifier=RDS_IDENTIFIER)
        instances = resp.get("DBInstances", [])
        if not instances:
            fail(f"RDS 인스턴스 '{RDS_IDENTIFIER}' 미존재")
            return None
        db = instances[0]
    except rds.exceptions.DBInstanceNotFoundFault:
        fail(f"RDS 인스턴스 '{RDS_IDENTIFIER}' 미존재")
        return None
    except Exception as e:
        fail(f"RDS 조회 실패: {e}")
        return None

    status = db["DBInstanceStatus"]
    info(f"인스턴스 상태: {status} | 엔진: {db['Engine']} {db['EngineVersion']} | 클래스: {db['DBInstanceClass']}")

    checks = [
        ("상태 AVAILABLE",          status == "available",                          f"상태={status}"),
        ("Multi-AZ 활성화",         db.get("MultiAZ", False),                       "MultiAZ=False"),
        ("스토리지 암호화",          db.get("StorageEncrypted", False),              "StorageEncrypted=False"),
        ("퍼블릭 접근 차단",         not db.get("PubliclyAccessible", True),         "PubliclyAccessible=True"),
        ("Deletion Protection",    db.get("DeletionProtection", False),             "DeletionProtection=False"),
        ("소수버전 자동업그레이드 OFF", not db.get("AutoMinorVersionUpgrade", True), "AutoMinorVersionUpgrade=True"),
    ]

    for label, condition, err_msg in checks:
        if condition:
            ok(label)
        else:
            fail(f"{label} — {err_msg}")

    # 백업 보존 기간
    backup_days = db.get("BackupRetentionPeriod", 0)
    if backup_days == 7:
        ok(f"백업 보존 기간 7일")
    elif backup_days > 0:
        fail(f"백업 보존 기간 {backup_days}일 (기대=7일)")
    else:
        fail("자동 백업 비활성화 (BackupRetentionPeriod=0)")

    # 백업 윈도우
    info(f"백업 윈도우: {db.get('PreferredBackupWindow', 'N/A')} UTC")
    info(f"유지보수 윈도우: {db.get('PreferredMaintenanceWindow', 'N/A')}")

    return db


# ──────────────────────────────────────────────────────────────────────────────
# TC-RDS-02: RDS Proxy 상태 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_rds_proxy():
    print(f"\n{'─'*60}")
    print("[TC-RDS-02] RDS Proxy 상태 확인")
    try:
        resp = rds.describe_db_proxies()
        proxies = resp.get("DBProxies", [])
        project_proxies = [p for p in proxies if PROJECT in p["DBProxyName"]]

        if not project_proxies:
            fail(f"프로젝트 '{PROJECT}' 관련 RDS Proxy 미존재")
            return

        for proxy in project_proxies:
            name   = proxy["DBProxyName"]
            status = proxy["Status"]
            endpoint = proxy.get("Endpoint", "N/A")
            info(f"RDS Proxy: {name} | 엔드포인트: {endpoint}")

            if status == "available":
                ok(f"RDS Proxy '{name}' 상태: {status}")
            else:
                fail(f"RDS Proxy '{name}' 상태 비정상: {status}")

            # 연결 풀 설정 확인
            engine_family = proxy.get("EngineFamily", "N/A")
            require_tls   = proxy.get("RequireTLS", False)
            info(f"  EngineFamily={engine_family}, RequireTLS={require_tls}")

    except Exception as e:
        fail(f"RDS Proxy 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-RDS-03: Secrets Manager 시크릿 존재 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_secrets():
    print(f"\n{'─'*60}")
    print("[TC-RDS-03] Secrets Manager 시크릿 존재 확인")

    secret_names = [
        (SECRET_DB_APP, "DB 앱 계정 자격증명"),
        (SECRET_JWT,    "JWT 서명 키"),
    ]

    for secret_name, label in secret_names:
        try:
            resp = sm.describe_secret(SecretId=secret_name)
            arn  = resp.get("ARN", "")
            name = resp.get("Name", "")
            ok(f"[{label}] 시크릿 존재: {name}")
            info(f"  ARN: {arn}")

            # 삭제 예약 여부 확인
            if resp.get("DeletedDate"):
                fail(f"[{label}] 시크릿이 삭제 예약 상태!")
            else:
                ok(f"[{label}] 삭제 예약 없음 — 정상")

        except sm.exceptions.ResourceNotFoundException:
            fail(f"[{label}] 시크릿 '{secret_name}' 미존재")
        except Exception as e:
            fail(f"[{label}] 시크릿 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-RDS-04: 최근 자동 스냅샷 존재 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_snapshots():
    print(f"\n{'─'*60}")
    print("[TC-RDS-04] 최근 자동 스냅샷 존재 확인")
    try:
        resp = rds.describe_db_snapshots(
            DBInstanceIdentifier=RDS_IDENTIFIER,
            SnapshotType="automated",
        )
        snapshots = resp.get("DBSnapshots", [])
        available = [s for s in snapshots if s["Status"] == "available"]

        if not available:
            fail("자동 스냅샷 없음 — 백업이 활성화되지 않았거나 아직 생성되지 않음")
            return

        latest = max(available, key=lambda s: s.get("SnapshotCreateTime", datetime.min.replace(tzinfo=None)))
        create_time = latest.get("SnapshotCreateTime")
        info(f"최근 스냅샷: {latest['DBSnapshotIdentifier']}")
        info(f"  생성 시각: {create_time}")
        ok(f"자동 스냅샷 {len(available)}개 존재")

    except Exception as e:
        fail(f"스냅샷 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\n{'#'*60}")
    print(f"# SecureVoice 04: RDS / RDS Proxy 연결성 검증")
    print(f"# 실행 시각: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"# RDS 식별자: {RDS_IDENTIFIER}")
    print(f"{'#'*60}")

    test_rds_instance()
    test_rds_proxy()
    test_secrets()
    test_snapshots()

    print(f"\n{'='*60}")
    total = results["pass"] + results["fail"]
    print(f"결과: {results['pass']}/{total} PASS  |  {results['fail']}/{total} FAIL")
    sys.exit(0 if results["fail"] == 0 else 1)
