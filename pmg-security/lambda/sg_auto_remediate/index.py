"""
SG 자동대응(self-healing) Lambda
--------------------------------
보안그룹에 위험한 인바운드(0.0.0.0/0 또는 ::/0 가 위험 포트로 열림)가 추가되면
- AUTO_REVOKE=false (기본/드라이런): 회수하지 않고 SNS 알림만 보냄(오탐 관찰용)
- AUTO_REVOKE=true            : 해당 인바운드 규칙을 자동 회수(revoke)하고 SNS 알림

안전장치
- 위험 포트(또는 전체 포트/전체 프로토콜)에 0.0.0.0/0·::/0 이 걸린 규칙만 대상.
- SG 태그 AutoRemediate=false 가 붙어 있으면 그 SG는 건드리지 않음(의도적 개방 예외 처리).
- CloudTrail 이벤트를 직접 파싱하지 않고, groupId 로 SG 현재 상태를 다시 조회해
  '실제로 지금 열려 있는' 규칙만 다룸(이벤트 형식 의존/오작동 최소화).
"""

import json
import os

import boto3

ec2 = boto3.client("ec2")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
AUTO_REVOKE = os.environ.get("AUTO_REVOKE", "false").lower() == "true"

# 인터넷 전체 개방으로 간주하는 CIDR
OPEN_V4 = "0.0.0.0/0"
OPEN_V6 = "::/0"

# 외부에 열리면 특히 위험한 포트(관리/DB/캐시 등)
RISKY_PORTS = {
    22,     # SSH
    23,     # Telnet
    21,     # FTP
    3389,   # RDP
    3306,   # MySQL/Aurora
    5432,   # PostgreSQL
    1433,   # MSSQL
    6379,   # Redis
    11211,  # Memcached
    27017,  # MongoDB
    9200,   # Elasticsearch
}

EXEMPT_TAG_KEY = "AutoRemediate"
EXEMPT_TAG_VALUE = "false"

# 처리 대상 이벤트
#  - AuthorizeSecurityGroupIngress: 인바운드 규칙 '추가'(새 규칙/새 SG 채우기 포함)
#  - ModifySecurityGroupRules     : 기존 규칙 '편집'(예: 10.0.0.0/16 → 0.0.0.0/0 으로 변경)
# 둘 다 SG 현재 상태를 재조회해 '실제로 열린' 위험 규칙만 처리하므로 동일 로직으로 안전 처리.
HANDLED_EVENTS = {"AuthorizeSecurityGroupIngress", "ModifySecurityGroupRules"}


def _port_range_is_risky(perm):
    """이 규칙(perm)이 위험 포트를 하나라도 덮는지 판단."""
    proto = str(perm.get("IpProtocol"))
    # -1 = 모든 프로토콜/모든 포트 → 무조건 위험
    if proto == "-1":
        return True
    from_port = perm.get("FromPort")
    to_port = perm.get("ToPort")
    # 포트 정보가 없으면(예: ICMP) 위험 포트 매칭 대상 아님
    if from_port is None or to_port is None:
        return False
    # 위험 포트 중 하나라도 [from, to] 범위에 들어오면 위험
    return any(from_port <= p <= to_port for p in RISKY_PORTS)


def _open_to_world(perm):
    """이 규칙이 0.0.0.0/0 또는 ::/0 를 포함하는지, 그리고 어떤 CIDR인지 반환."""
    cidrs = []
    for r in perm.get("IpRanges", []):
        if r.get("CidrIp") == OPEN_V4:
            cidrs.append(OPEN_V4)
    for r in perm.get("Ipv6Ranges", []):
        if r.get("CidrIpv6") == OPEN_V6:
            cidrs.append(OPEN_V6)
    return cidrs


def _build_revoke_permission(perm, open_cidrs):
    """RevokeSecurityGroupIngress 에 넘길, '열린 CIDR만' 골라낸 최소 규칙 생성."""
    revoke = {"IpProtocol": perm["IpProtocol"]}
    if "FromPort" in perm:
        revoke["FromPort"] = perm["FromPort"]
    if "ToPort" in perm:
        revoke["ToPort"] = perm["ToPort"]
    if OPEN_V4 in open_cidrs:
        revoke["IpRanges"] = [{"CidrIp": OPEN_V4}]
    if OPEN_V6 in open_cidrs:
        revoke["Ipv6Ranges"] = [{"CidrIpv6": OPEN_V6}]
    return revoke


def _notify(subject, lines):
    msg = "\n".join(lines)
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=msg)
    print(json.dumps({"sns_subject": subject, "message": msg}))


def _extract_group_id(detail):
    """이벤트 형식이 달라도 groupId 를 최대한 견고하게 추출.

    - AuthorizeSecurityGroupIngress: requestParameters.groupId
    - ModifySecurityGroupRules     : requestParameters.ModifySecurityGroupRulesRequest.groupId
      (CloudTrail 이 키 대소문자를 groupId/GroupId 로 다르게 기록하는 경우까지 대비)
    """
    rp = detail.get("requestParameters") or {}
    if rp.get("groupId"):
        return rp["groupId"]
    modify = rp.get("ModifySecurityGroupRulesRequest") or {}
    return modify.get("groupId") or modify.get("GroupId")


def handler(event, context):
    detail = event.get("detail", {})
    event_name = detail.get("eventName", "")

    # 인바운드 추가(Authorize) + 기존 규칙 편집(Modify)만 처리.
    # 아웃바운드(egress)/기타 이벤트는 무시 → 같은 EventBridge 규칙을 공유해도 안전.
    if event_name not in HANDLED_EVENTS:
        print(f"skip: eventName={event_name}")
        return {"status": "skipped", "reason": event_name}

    group_id = _extract_group_id(detail)
    if not group_id:
        print("skip: groupId not found in event")
        return {"status": "skipped", "reason": "no groupId"}

    actor = (detail.get("userIdentity") or {}).get("arn", "unknown")

    resp = ec2.describe_security_groups(GroupIds=[group_id])
    sg = resp["SecurityGroups"][0]
    sg_name = sg.get("GroupName", "")

    # 예외 태그 확인 → 의도적으로 열어둔 SG 는 건드리지 않음
    tags = {t["Key"]: t["Value"] for t in sg.get("Tags", [])}
    if tags.get(EXEMPT_TAG_KEY) == EXEMPT_TAG_VALUE:
        print(f"skip: {group_id} has {EXEMPT_TAG_KEY}={EXEMPT_TAG_VALUE}")
        return {"status": "skipped", "reason": "exempt tag"}

    # 현재 인바운드 규칙 중 '위험 + 인터넷 전체 개방' 만 추출
    offenders = []
    for perm in sg.get("IpPermissions", []):
        open_cidrs = _open_to_world(perm)
        if open_cidrs and _port_range_is_risky(perm):
            offenders.append((perm, open_cidrs))

    if not offenders:
        print(f"ok: {group_id} has no risky world-open ingress")
        return {"status": "clean", "group_id": group_id}

    # 알림 메시지 구성
    proto_desc = []
    revoked = []
    for perm, open_cidrs in offenders:
        p = perm.get("IpProtocol")
        fr = perm.get("FromPort", "all")
        to = perm.get("ToPort", "all")
        proto_desc.append(f"  - proto={p} ports={fr}-{to} open_to={','.join(open_cidrs)}")

        if AUTO_REVOKE:
            try:
                ec2.revoke_security_group_ingress(
                    GroupId=group_id,
                    IpPermissions=[_build_revoke_permission(perm, open_cidrs)],
                )
                revoked.append(f"  - proto={p} ports={fr}-{to} ({','.join(open_cidrs)})")
            except Exception as e:  # noqa: BLE001 - 알림에 실패사유 포함
                revoked.append(f"  - REVOKE FAILED proto={p} ports={fr}-{to}: {e}")

    mode = "AUTO-REVOKED" if AUTO_REVOKE else "DRY-RUN (alert only)"
    lines = [
        f"[SG 자동대응] {mode}",
        f"보안그룹: {sg_name} ({group_id})",
        f"수행 주체(actor): {actor}",
        f"이벤트: {event_name}",
        "",
        "위험 인바운드(인터넷 전체 개방 + 위험 포트):",
        *proto_desc,
    ]
    if AUTO_REVOKE:
        lines += ["", "회수(revoke) 결과:", *revoked]
    else:
        lines += ["", "※ 드라이런 모드: 자동 회수하지 않음. AUTO_REVOKE=true 로 켜면 자동 회수됩니다."]

    _notify(f"[보안경보] SG 위험 개방 탐지: {sg_name}", lines)
    return {
        "status": "revoked" if AUTO_REVOKE else "alerted",
        "group_id": group_id,
        "offenders": len(offenders),
    }
