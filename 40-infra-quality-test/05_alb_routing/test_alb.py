"""
[SecureVoice] 05: ALB 트래픽 처리 검증

검증 항목:
  - ALB 존재 및 상태 active
  - Target Group 존재 및 Health Check 설정값 검증
    · path=/api/health, matcher=200, interval=30, timeout=5
    · healthy_threshold=2, unhealthy_threshold=3
  - Listener Rule: /api/* → Target Group 포워딩 존재
  - Default Action: fixed-response (200) — API가 아닌 경로 처리
  - 실제 HTTP 요청 검증:
    · GET /api/health → HTTP 200
    · GET /api/nonexistent-path → HTTP 404 or 422 (ALB는 통과, 앱이 처리)
    · GET / (루트) → ALB fixed-response 200
  - Route53 레코드 존재 확인 (api-origin.mzmt.shop)
"""

import os
import sys
from datetime import datetime

import boto3
import requests

AWS_REGION  = os.environ.get("AWS_REGION", "ap-northeast-2")
AWS_PROFILE = os.environ.get("AWS_PROFILE", "bya")
ALB_NAME    = os.environ.get("ALB_NAME", "securevoice-dev-api-alb")
API_HOST    = os.environ.get("API_HOST", "http://api-origin.mzmt.shop")
PROJECT     = os.environ.get("PROJECT", "securevoice")
ENV         = os.environ.get("ENV", "dev")

PASS_STR = "\033[92m[PASS]\033[0m"
FAIL_STR = "\033[91m[FAIL]\033[0m"
INFO_STR = "\033[94m[INFO]\033[0m"
WARN_STR = "\033[93m[WARN]\033[0m"

session = boto3.Session(region_name=AWS_REGION, profile_name=AWS_PROFILE)
elbv2   = session.client("elbv2")
r53     = session.client("route53")

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
# TC-ALB-01: ALB 상태 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_alb_state():
    print(f"\n{'─'*60}")
    print(f"[TC-ALB-01] ALB 상태 확인: {ALB_NAME}")
    try:
        resp  = elbv2.describe_load_balancers(Names=[ALB_NAME])
        lbs   = resp.get("LoadBalancers", [])
        if not lbs:
            fail(f"ALB '{ALB_NAME}' 미존재")
            return None
        lb     = lbs[0]
        state  = lb["State"]["Code"]
        scheme = lb["Scheme"]
        dns    = lb["DNSName"]
        info(f"DNS: {dns} | Scheme: {scheme}")

        if state == "active":
            ok(f"ALB 상태: {state}")
        else:
            fail(f"ALB 상태 비정상: {state}")

        if scheme == "internet-facing":
            ok("Scheme: internet-facing (공개 ALB)")
        else:
            fail(f"Scheme 비정상: {scheme} (기대=internet-facing)")

        return lb["LoadBalancerArn"]
    except Exception as e:
        fail(f"ALB 조회 실패: {e}")
        return None


# ──────────────────────────────────────────────────────────────────────────────
# TC-ALB-02: Target Group Health Check 설정값 검증
# ──────────────────────────────────────────────────────────────────────────────
def test_target_group(alb_arn: str):
    print(f"\n{'─'*60}")
    print("[TC-ALB-02] Target Group Health Check 설정 검증")
    try:
        resp = elbv2.describe_target_groups(LoadBalancerArn=alb_arn)
        tgs  = resp.get("TargetGroups", [])
        if not tgs:
            fail("Target Group 미존재")
            return

        for tg in tgs:
            name = tg["TargetGroupName"]

            # API TG만 검증 대상으로 한정 (Jenkins 등 다른 TG 제외)
            if "api-tg" not in name:
                info(f"Target Group '{name}' — API TG가 아니므로 스킵")
                continue

            expected = {
                "HealthCheckPath":             "/api/health",
                "HealthCheckIntervalSeconds":  30,
                "HealthCheckTimeoutSeconds":   5,
                "HealthyThresholdCount":       2,
                "UnhealthyThresholdCount":     3,
                "HealthCheckProtocol":         "HTTP",
            }
            errors = []
            for key, exp_val in expected.items():
                actual = tg.get(key)
                if actual != exp_val:
                    errors.append(f"{key}={actual} (기대={exp_val})")

            if errors:
                fail(f"[{name}] Health Check 설정 불일치: {', '.join(errors)}")
            else:
                ok(f"[{name}] Health Check 설정 정상")

            # Health Check matcher
            matcher = tg.get("Matcher", {}).get("HttpCode", "")
            if matcher == "200":
                ok(f"[{name}] Matcher=200")
            else:
                fail(f"[{name}] Matcher={matcher} (기대=200)")

    except Exception as e:
        fail(f"Target Group 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-ALB-03: Listener Rule 검증 (/api/* → forward)
# ──────────────────────────────────────────────────────────────────────────────
def test_listener_rules(alb_arn: str):
    print(f"\n{'─'*60}")
    print("[TC-ALB-03] Listener Rule 검증")
    try:
        listeners = elbv2.describe_listeners(LoadBalancerArn=alb_arn).get("Listeners", [])
        if not listeners:
            fail("Listener 미존재")
            return

        for listener in listeners:
            port     = listener["Port"]
            protocol = listener["Protocol"]
            info(f"Listener: {protocol}:{port}")

            rules = elbv2.describe_rules(ListenerArn=listener["ListenerArn"]).get("Rules", [])
            api_rule_found   = False
            default_fixed_ok = False

            for rule in rules:
                conditions = rule.get("Conditions", [])
                actions    = rule.get("Actions", [])

                # /api/* 룰 확인
                for cond in conditions:
                    if cond.get("Field") == "path-pattern":
                        paths = cond.get("Values", []) or cond.get("PathPatternConfig", {}).get("Values", [])
                        if "/api/*" in paths:
                            if any(a["Type"] == "forward" for a in actions):
                                api_rule_found = True

                # default action (fixed-response)
                if rule.get("IsDefault"):
                    for action in actions:
                        if action["Type"] == "fixed-response":
                            code = action.get("FixedResponseConfig", {}).get("StatusCode", "")
                            if code == "200":
                                default_fixed_ok = True

            if api_rule_found:
                ok("Listener Rule: /api/* → forward(Target Group) 존재")
            else:
                fail("Listener Rule: /api/* → forward 규칙 없음")

            if default_fixed_ok:
                ok("Default Action: fixed-response 200 존재")
            else:
                fail("Default Action: fixed-response 200 미존재")

    except Exception as e:
        fail(f"Listener Rule 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-ALB-04: 실제 HTTP 요청 검증
# ──────────────────────────────────────────────────────────────────────────────
def test_http_endpoints():
    print(f"\n{'─'*60}")
    print(f"[TC-ALB-04] 실제 HTTP 요청 검증: {API_HOST}")

    test_cases = [
        ("/api/health",           [200],          "Health Check 엔드포인트"),
        ("/",                     [200],          "루트(fixed-response)"),
        ("/api/nonexistent-9999", [404, 422, 405], "존재하지 않는 API 경로 (ALB 통과)"),
    ]

    for path, expected_codes, label in test_cases:
        url = f"{API_HOST}{path}"
        try:
            resp = requests.get(url, timeout=10, allow_redirects=True)
            if resp.status_code in expected_codes:
                ok(f"[{label}] HTTP {resp.status_code} (소요: {resp.elapsed.total_seconds()*1000:.0f}ms)")
            else:
                fail(f"[{label}] HTTP {resp.status_code} (기대: {expected_codes})")
        except requests.exceptions.ConnectionError:
            fail(f"[{label}] 연결 실패: {url}")
        except requests.exceptions.Timeout:
            fail(f"[{label}] 타임아웃 (10s)")
        except Exception as e:
            fail(f"[{label}] 요청 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# TC-ALB-05: Route53 레코드 존재 확인
# ──────────────────────────────────────────────────────────────────────────────
def test_route53_record():
    print(f"\n{'─'*60}")
    print("[TC-ALB-05] Route53 레코드 확인 (api-origin.mzmt.shop)")
    try:
        zones = r53.list_hosted_zones_by_name(DNSName="mzmt.shop.")
        hosted_zones = [z for z in zones.get("HostedZones", []) if "mzmt.shop" in z["Name"]]

        if not hosted_zones:
            fail("Route53 Hosted Zone 'mzmt.shop' 미존재")
            return

        zone_id = hosted_zones[0]["Id"].split("/")[-1]
        info(f"Hosted Zone ID: {zone_id}")

        records = r53.list_resource_record_sets(
            HostedZoneId=zone_id,
            StartRecordName="api-origin.mzmt.shop",
            StartRecordType="A",
            MaxItems="5",
        )
        rrsets = records.get("ResourceRecordSets", [])
        api_records = [r for r in rrsets if "api-origin" in r.get("Name", "")]

        if api_records:
            rec = api_records[0]
            alias = rec.get("AliasTarget", {})
            ok(f"레코드 존재: {rec['Name']} → {alias.get('DNSName', 'N/A')}")
        else:
            fail("Route53 레코드 'api-origin.mzmt.shop' 미존재")

    except Exception as e:
        fail(f"Route53 조회 실패: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\n{'#'*60}")
    print(f"# SecureVoice 05: ALB 트래픽 처리 검증")
    print(f"# 실행 시각: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"# ALB: {ALB_NAME}  |  API_HOST: {API_HOST}")
    print(f"{'#'*60}")

    alb_arn = test_alb_state()
    if alb_arn:
        test_target_group(alb_arn)
        test_listener_rules(alb_arn)
    test_http_endpoints()
    test_route53_record()

    print(f"\n{'='*60}")
    total = results["pass"] + results["fail"]
    print(f"결과: {results['pass']}/{total} PASS  |  {results['fail']}/{total} FAIL")
    sys.exit(0 if results["fail"] == 0 else 1)
