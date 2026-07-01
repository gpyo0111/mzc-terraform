"""
[SecureVoice] 테스트 1: SQS DLQ 격리 & 재처리 흐름
검증 항목: 2026-01-01 ~ 2026-01-09
"""
import boto3, json, time, uuid, threading, sys
from datetime import datetime
from config import *

sqs = boto3.client("sqs", region_name=AWS_REGION)

PASS = "\033[92m[PASS]\033[0m"
FAIL = "\033[91m[FAIL]\033[0m"
INFO = "\033[94m[INFO]\033[0m"

def get_queue_depth(url):
    r = sqs.get_queue_attributes(QueueUrl=url,
        AttributeNames=["ApproximateNumberOfMessages","ApproximateNumberOfMessagesNotVisible"])
    attrs = r["Attributes"]
    return int(attrs["ApproximateNumberOfMessages"]), int(attrs["ApproximateNumberOfMessagesNotVisible"])

def purge_queues():
    print(f"{INFO} 테스트 전 큐 초기화 중...")
    for url in [MAIN_QUEUE_URL, DLQ_URL]:
        try:
            sqs.purge_queue(QueueUrl=url)
            time.sleep(2)
        except Exception as e:
            print(f"  purge 스킵 (60초 제한): {e}")

# ──────────────────────────────────────────────
# 2026-01-01 / 2026-01-02: 불량 JSON 주입 → 워커 예외 처리 확인
# ──────────────────────────────────────────────
def test_01_broken_json_injection():
    print(f"\n{'='*60}")
    print(f"[2026-01-01/02] 불량 JSON 메시지 주입 → 워커 예외 처리 확인")
    broken_body = '{"request_id": "test-broken-' + str(uuid.uuid4())[:8] + '", "s3_key":' # 의도적 파싱 오류
    r = sqs.send_message(QueueUrl=MAIN_QUEUE_URL, MessageBody=broken_body)
    msg_id = r["MessageId"]
    print(f"{INFO} 불량 메시지 주입 완료: MessageId={msg_id}")
    print(f"{INFO} 워커 로그 확인 명령어 (CloudWatch):")
    print(f"  aws logs filter-log-events --log-group-name {LOG_GROUP_WORKER} \\")
    print(f"    --filter-pattern 'JSONDecodeError' --start-time $(date -d '1 min ago' +%s000)")
    print(f"{INFO} 5초 대기 후 DLQ 카운트 확인...")
    time.sleep(5)
    dlq_vis, dlq_invis = get_queue_depth(DLQ_URL)
    main_vis, _ = get_queue_depth(MAIN_QUEUE_URL)
    print(f"  Main Queue depth: {main_vis} / DLQ depth: {dlq_vis}")
    print(f"  → 워커가 Nack 처리 중이면 Main Queue InFlight 증가 확인 필요")
    print(f"{INFO} 수동 확인: CloudWatch Logs에서 'JSONDecodeError' OR 'invalid message' 키워드 존재 여부")
    return msg_id

# ──────────────────────────────────────────────
# 2026-01-03 / 2026-01-04: Max Receive Count → DLQ 자동 이관
# ──────────────────────────────────────────────
def test_02_dlq_auto_routing():
    print(f"\n{'='*60}")
    print(f"[2026-01-03/04] MaxReceiveCount 초과 → DLQ 자동 이관 검증")
    test_id = f"dlq-test-{uuid.uuid4()}"
    broken_body = json.dumps({"request_id": test_id, "s3_key": "INVALID_KEY_DOES_NOT_EXIST"})
    dlq_before, _ = get_queue_depth(DLQ_URL)
    sqs.send_message(QueueUrl=MAIN_QUEUE_URL, MessageBody=broken_body)
    print(f"{INFO} 메시지 주입: request_id={test_id}")
    print(f"{INFO} DLQ 이관 대기 중 (Max Receive Count={MAX_RECEIVE_COUNT}회, 최대 5분)...")
    timeout = 300
    start = time.time()
    while time.time() - start < timeout:
        dlq_now, _ = get_queue_depth(DLQ_URL)
        if dlq_now > dlq_before:
            elapsed = int(time.time() - start)
            print(f"{PASS} DLQ 메시지 수 증가 확인: {dlq_before} → {dlq_now} (소요: {elapsed}초)")
            if elapsed <= 60:
                print(f"{PASS} [2026-01-04] 60초 이내 DLQ 이관 완료")
            else:
                print(f"{FAIL} [2026-01-04] 60초 초과 ({elapsed}초) — 임계값 재검토 필요")
            return True
        time.sleep(10)
        print(f"  대기 중... {int(time.time()-start)}초 경과 / DLQ: {dlq_now}")
    print(f"{FAIL} [2026-01-04] {timeout}초 내 DLQ 이관 미확인")
    return False

# ──────────────────────────────────────────────
# 2026-01-05: DLQ 메시지 적재 → 알림 트리거 확인
# ──────────────────────────────────────────────
def test_03_dlq_alarm():
    print(f"\n{'='*60}")
    print(f"[2026-01-05] DLQ 알림(CloudWatch Alarm) 트리거 확인")
    cw = boto3.client("cloudwatch", region_name=AWS_REGION)
    alarms = cw.describe_alarms(AlarmNamePrefix="securevoice-dlq")
    if not alarms["MetricAlarms"]:
        print(f"{FAIL} CloudWatch Alarm 'securevoice-dlq*' 미존재 — Alarm 생성 필요")
        print(f"  생성 명령어:")
        print(f"  aws cloudwatch put-metric-alarm --alarm-name securevoice-dlq-alert \\")
        print(f"    --metric-name ApproximateNumberOfMessagesVisible \\")
        print(f"    --namespace AWS/SQS --dimensions Name=QueueName,Value=securevoice-dlq \\")
        print(f"    --statistic Sum --period 60 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \\")
        print(f"    --evaluation-periods 1 --alarm-actions $SNS_TOPIC_ARN")
        return False
    for alarm in alarms["MetricAlarms"]:
        state = alarm["StateValue"]
        print(f"{INFO} Alarm '{alarm['AlarmName']}': 상태={state}")
        if state == "ALARM":
            print(f"{PASS} [2026-01-05] DLQ Alarm ALARM 상태 확인")
        else:
            print(f"{INFO} [2026-01-05] 현재 OK 상태 (DLQ에 메시지 적재 후 60초 내 ALARM 전환 확인 필요)")
    return True

# ──────────────────────────────────────────────
# 2026-01-06: DLQ Redrive → 원본 큐 복귀
# ──────────────────────────────────────────────
def test_04_dlq_redrive():
    print(f"\n{'='*60}")
    print(f"[2026-01-06] DLQ → 원본 큐 Redrive 검증")
    dlq_before, _ = get_queue_depth(DLQ_URL)
    main_before, _ = get_queue_depth(MAIN_QUEUE_URL)
    if dlq_before == 0:
        print(f"{INFO} DLQ가 비어있음 — test_02 먼저 실행하여 메시지 적재 필요")
        return False
    print(f"{INFO} Redrive 시작: DLQ({dlq_before}) → Main({main_before})")
    try:
        r = sqs.start_message_move_task(SourceArn=DLQ_ARN, DestinationArn=MAIN_QUEUE_ARN)
        task_handle = r.get("TaskHandle", "")
        print(f"{INFO} Redrive 태스크 시작: {task_handle}")
    except Exception as e:
        print(f"{INFO} Redrive API 오류 (권한 또는 설정 확인): {e}")
        print(f"  수동 실행: AWS 콘솔 → SQS → securevoice-dlq → 'Start DLQ redrive'")
        return False
    time.sleep(30)
    dlq_after, _ = get_queue_depth(DLQ_URL)
    main_after, _ = get_queue_depth(MAIN_QUEUE_URL)
    if dlq_after < dlq_before:
        print(f"{PASS} [2026-01-06] DLQ 메시지 감소: {dlq_before} → {dlq_after}")
        print(f"{INFO} Main Queue: {main_before} → {main_after}")
    else:
        print(f"{FAIL} [2026-01-06] DLQ 메시지 미감소: {dlq_before} → {dlq_after}")
    return dlq_after < dlq_before

# ──────────────────────────────────────────────
# 2026-01-07: 악성 인젝션 페이로드 → ValidationError → DLQ
# ──────────────────────────────────────────────
def test_05_injection_validation():
    print(f"\n{'='*60}")
    print(f"[2026-01-07] 악성 인젝션 페이로드 → ValidationError 검증")
    injection_cases = [
        {"request_id": "1; DROP TABLE requests;--", "s3_key": "normal/key.wav"},
        {"request_id": "valid-id-001", "s3_key": "../../../etc/passwd"},
        {"request_id": "<script>alert(1)</script>", "s3_key": "normal/key.wav"},
    ]
    dlq_before, _ = get_queue_depth(DLQ_URL)
    for case in injection_cases:
        sqs.send_message(QueueUrl=MAIN_QUEUE_URL, MessageBody=json.dumps(case))
        print(f"{INFO} 인젝션 메시지 주입: {json.dumps(case)[:60]}")
    print(f"{INFO} 30초 대기 후 DLQ 이관 및 DB 무결성 확인...")
    time.sleep(30)
    dlq_after, _ = get_queue_depth(DLQ_URL)
    print(f"{INFO} DLQ 변화: {dlq_before} → {dlq_after} (+{dlq_after - dlq_before}건)")
    print(f"{INFO} DB 무결성 확인 쿼리:")
    print(f"  mysql -h {DB_HOST} -u {DB_USER} -e \"SELECT request_id FROM requests WHERE request_id LIKE '%DROP%' OR request_id LIKE '%script%'\"")
    print(f"  → 결과 0건이면 {PASS} ValidationError 정상 동작")

# ──────────────────────────────────────────────
# 2026-01-08: 동시 대량 불량 메시지 스파이크 → 정상 워커 격리
# ──────────────────────────────────────────────
def test_06_spike_isolation():
    print(f"\n{'='*60}")
    print(f"[2026-01-08] 동시 대량 불량 메시지 스파이크 테스트 (100건)")
    SPIKE_COUNT = 100
    THREADS = 10
    sent = {"count": 0}
    lock = threading.Lock()

    def send_batch(n):
        for _ in range(n):
            broken = '{"broken":true, "id":"' + str(uuid.uuid4()) + '"'  # 의도적 파싱 오류
            sqs.send_message(QueueUrl=MAIN_QUEUE_URL, MessageBody=broken)
            with lock:
                sent["count"] += 1

    # 동시 정상 메시지도 함께 주입 (격리 확인용)
    normal_ids = [str(uuid.uuid4()) for _ in range(5)]
    for nid in normal_ids:
        sqs.send_message(QueueUrl=MAIN_QUEUE_URL,
            MessageBody=json.dumps({"request_id": nid, "s3_key": "test/normal.wav"}))

    threads = [threading.Thread(target=send_batch, args=(SPIKE_COUNT//THREADS,)) for _ in range(THREADS)]
    t_start = time.time()
    for t in threads: t.start()
    for t in threads: t.join()
    elapsed = time.time() - t_start
    print(f"{INFO} {sent['count']}건 불량 메시지 주입 완료 ({elapsed:.1f}초)")
    print(f"{INFO} 정상 메시지 5건 동시 주입 (격리 테스트용)")
    print(f"{INFO} 30초 후 정상 메시지 처리 여부 확인:")
    print(f"  → DB에서 normal_ids 처리 완료 여부 확인:")
    for nid in normal_ids:
        print(f"    SELECT status FROM requests WHERE request_id='{nid}'")
    print(f"{INFO} 기준: 정상 메시지 처리 지연 < baseline × 2배")

# ──────────────────────────────────────────────
# 2026-01-09: Redrive 멱등성(Idempotency) 검증
# ──────────────────────────────────────────────
def test_07_idempotency():
    print(f"\n{'='*60}")
    print(f"[2026-01-09] DLQ Redrive 멱등성(Idempotency) 검증")
    test_id = f"idempotency-test-{uuid.uuid4()}"
    print(f"{INFO} 테스트 request_id: {test_id}")
    print(f"{INFO} 동일 메시지를 2회 처리 시도 → DB 중복 레코드 확인")
    print(f"\n  수동 검증 쿼리 (Redrive 2회 후 실행):")
    print(f"  mysql -h {DB_HOST} -u {DB_USER} {DB_NAME} -e \\")
    print(f"    \"SELECT COUNT(*) as cnt FROM requests WHERE request_id='{test_id}'\"")
    print(f"  → 기준: cnt = 1 (중복 없음) → {PASS}")
    print(f"  → 기준: cnt > 1 (중복 발생) → {FAIL} UPSERT/Idempotency 로직 점검 필요")

# ──────────────────────────────────────────────
# 메인 실행
# ──────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\n{'#'*60}")
    print(f"# SecureVoice 테스트 1: SQS DLQ 격리 & 재처리")
    print(f"# 실행 시각: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"# 대상 큐: {MAIN_QUEUE_URL}")
    print(f"{'#'*60}")

    purge_queues()
    test_01_broken_json_injection()
    test_02_dlq_auto_routing()
    test_03_dlq_alarm()
    test_04_dlq_redrive()
    test_05_injection_validation()
    test_06_spike_isolation()
    test_07_idempotency()

    print(f"\n{'='*60}")
    print(f"테스트 1 완료. CloudWatch Logs에서 워커 로그 수동 확인 필요:")
    print(f"  aws logs tail {LOG_GROUP_WORKER} --follow")
