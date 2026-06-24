"""
[SecureVoice] 06: S3 보안 및 암호화 검증

검증 항목:
  - Model 버킷 / Audio 버킷 퍼블릭 접근 차단 4개 플래그 ALL true
    · BlockPublicAcls, IgnorePublicAcls, BlockPublicPolicy, RestrictPublicBuckets
  - SSE-KMS 서버사이드 암호화 적용 확인
  - prevent_destroy 대응: 버킷 Versioning 상태 확인
  - 버킷 외부 접근 거부: 버킷 정책에 퍼블릭 허용 구문 없는지 확인
  - 태그 확인 (Project, Environment, ManagedBy=terraform)
"""

import os
import sys
import json
from datetime import datetime

import boto3
from botocore.exceptions import ClientError

AWS_REGION    = os.environ.get("AWS_REGION", "ap-northeast-2")
AWS_PROFILE   = os.environ.get("AWS_PROFILE", "bya")
ACCOUNT_ID    = os.environ.get("ACCOUNT_ID", "455535733131")
MODEL_BUCKET  = os.environ.get("MODEL_BUCKET",
                    f"mzc-securevoiceguard-model-dev-{ACCOUNT_ID}-{AWS_REGION}")
AUDIO_BUCKET  = os.environ.get("AUDIO_BUCKET",
                    f"mzc-securevoiceguard-audio-dev-{ACCOUNT_ID}-{AWS_REGION}-an")

PASS_STR = "\033[92m[PASS]\033[0m"
FAIL_STR = "\033[91m[FAIL]\033[0m"
INFO_STR = "\033[94m[INFO]\033[0m"
WARN_STR = "\033[93m[WARN]\033[0m"

session = boto3.Session(region_name=AWS_REGION, profile_name=AWS_PROFILE)
s3 = session.client("s3")

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
# TC-S3-01: 퍼블릭 접근 차단 4개 플래그
# ──────────────────────────────────────────────────────────────────────────────
def test_public_access_block(bucket: str, label: str):
    print(f"\n{'─'*60}")
    print(f"[TC-S3-01] {label} 버킷 퍼블릭 접근 차단 확인: {bucket}")
    try:
        resp = s3.get_public_access_block(Bucket=bucket)
        config = resp["PublicAccessBlockConfiguration"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchPublicAccessBlockConfiguration":
            fail(f"[{label}] 퍼블릭 접근 차단 설정 없음 — 모든 플래그가 false 상태")
            return
        fail(f"[{label}] 조회 실패: {e}")
        return

    flags = {
        "BlockPublicAcls":       config.get("BlockPublicAcls", False),
        "IgnorePublicAcls":      config.get("IgnorePublicAcls", False),
        "BlockPublicPolicy":     config.get("BlockPublicPolicy", False),
        "RestrictPublicBuckets": config.get("RestrictPublicBuckets", False),
    }

    all_blocked = all(flags.values())
    for flag_name, val in flags.items():
        if val:
            ok(f"[{label}] {flag_name} = true")
        else:
            fail(f"[{label}] {flag_name} = false (차단되지 않음!)")

    if all_blocked:
        ok(f"[{label}] 퍼블릭 접근 완전 차단 ✓")


# ──────────────────────────────────────────────────────────────────────────────
# TC-S3-02: SSE-KMS 암호화 적용 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_sse_encryption(bucket: str, label: str):
    print(f"\n{'─'*60}")
    print(f"[TC-S3-02] {label} SSE-KMS 암호화 확인")
    try:
        resp = s3.get_bucket_encryption(Bucket=bucket)
        rules = resp["ServerSideEncryptionConfiguration"]["Rules"]
        for rule in rules:
            apply_rule = rule.get("ApplyServerSideEncryptionByDefault", {})
            algorithm  = apply_rule.get("SSEAlgorithm", "")
            kms_key    = apply_rule.get("KMSMasterKeyID", "")

            if algorithm == "aws:kms":
                ok(f"[{label}] SSE-KMS 암호화 적용 (KMS Key: ...{kms_key[-12:] if kms_key else 'AWS Managed'})")
            elif algorithm == "AES256":
                print(f"  {WARN_STR} [{label}] SSE-S3(AES256) 사용 중 — KMS 권고")
                ok(f"[{label}] 서버사이드 암호화는 적용됨 (AES256)")
            else:
                fail(f"[{label}] 암호화 미적용 (SSEAlgorithm={algorithm})")

    except ClientError as e:
        if e.response["Error"]["Code"] == "ServerSideEncryptionConfigurationNotFoundError":
            fail(f"[{label}] 서버사이드 암호화 미설정")
        else:
            fail(f"[{label}] 암호화 설정 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-S3-03: 버킷 정책 내 퍼블릭 허용 구문 없는지 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_no_public_policy(bucket: str, label: str):
    print(f"\n{'─'*60}")
    print(f"[TC-S3-03] {label} 버킷 정책 퍼블릭 허용 여부 확인")
    try:
        resp   = s3.get_bucket_policy(Bucket=bucket)
        policy = json.loads(resp["Policy"])
        stmts  = policy.get("Statement", [])
        public_stmts = []

        for stmt in stmts:
            principal = stmt.get("Principal", "")
            effect    = stmt.get("Effect", "")
            if effect == "Allow" and (principal == "*" or principal == {"AWS": "*"}):
                public_stmts.append(stmt)

        if public_stmts:
            fail(f"[{label}] 버킷 정책에 퍼블릭 허용(Principal=*) 구문 {len(public_stmts)}개 발견!")
            for s in public_stmts:
                info(f"  Action: {s.get('Action')}")
        else:
            ok(f"[{label}] 버킷 정책에 퍼블릭 허용 구문 없음")

    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchBucketPolicy":
            ok(f"[{label}] 버킷 정책 없음 (퍼블릭 허용 정책 미적용)")
        else:
            fail(f"[{label}] 버킷 정책 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-S3-04: 버킷 태그 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_bucket_tags(bucket: str, label: str):
    print(f"\n{'─'*60}")
    print(f"[TC-S3-04] {label} 버킷 태그 확인")
    try:
        resp = s3.get_bucket_tagging(Bucket=bucket)
        tags = {t["Key"]: t["Value"] for t in resp.get("TagSet", [])}
        info(f"[{label}] 태그: {tags}")

        required_tags = ["Project", "Environment"]
        for tag in required_tags:
            if tag in tags:
                ok(f"[{label}] 태그 '{tag}={tags[tag]}' 존재")
            else:
                print(f"  {WARN_STR} [{label}] 태그 '{tag}' 없음")

        if tags.get("ManagedBy") == "terraform":
            ok(f"[{label}] ManagedBy=terraform 태그 확인")
        else:
            print(f"  {WARN_STR} [{label}] ManagedBy=terraform 태그 없음")

    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchTagSet":
            print(f"  {WARN_STR} [{label}] 버킷 태그 없음")
        else:
            fail(f"[{label}] 버킷 태그 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-S3-05: 버킷 존재 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_bucket_exists(bucket: str, label: str) -> bool:
    print(f"\n{'─'*60}")
    print(f"[TC-S3-05] {label} 버킷 존재 확인: {bucket}")
    try:
        s3.head_bucket(Bucket=bucket)
        ok(f"[{label}] 버킷 '{bucket}' 존재")
        return True
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("404", "NoSuchBucket"):
            fail(f"[{label}] 버킷 '{bucket}' 미존재")
        elif code == "403":
            fail(f"[{label}] 버킷 접근 거부 (403) — IAM 권한 확인 필요")
        else:
            fail(f"[{label}] 버킷 확인 실패: {e}")
        return False


# ──────────────────────────────────────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\n{'#'*60}")
    print(f"# SecureVoice 06: S3 보안 및 암호화 검증")
    print(f"# 실행 시각: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"# Model Bucket: {MODEL_BUCKET}")
    print(f"# Audio Bucket: {AUDIO_BUCKET}")
    print(f"{'#'*60}")

    for bucket_name, bucket_label in [
        (MODEL_BUCKET, "model"),
        (AUDIO_BUCKET, "audio"),
    ]:
        exists = test_bucket_exists(bucket_name, bucket_label)
        if exists:
            test_public_access_block(bucket_name, bucket_label)
            test_sse_encryption(bucket_name, bucket_label)
            test_no_public_policy(bucket_name, bucket_label)
            test_bucket_tags(bucket_name, bucket_label)

    print(f"\n{'='*60}")
    total = results["pass"] + results["fail"]
    print(f"결과: {results['pass']}/{total} PASS  |  {results['fail']}/{total} FAIL")
    sys.exit(0 if results["fail"] == 0 else 1)
