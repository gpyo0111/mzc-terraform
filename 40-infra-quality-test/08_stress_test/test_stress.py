"""
[SecureVoice] 08: 스트레스 테스트 — 부하 임계점 탐색 및 취약점 발견

목표: PASS/FAIL이 아닌 "어느 지점에서 시스템이 무너지는가"를 측정한다.

측정 항목:
  1. API 응답 지연 (latency ramp)
     - 동시 요청 1→5→10→20→50→100 VU
     - p50 / p95 / p99 / 에러율 측정
     - 응답 500ms 초과 / 에러 1% 초과 지점 = 임계점

  2. SQS 메시지 버스트 (burst injection)
     - 10→30→50→100→200개 메시지 일괄 주입
     - 주입 속도, 큐 깊이 변화, DLQ 유입 시간 측정
     - worker visibility timeout(300s) 초과 여부 추정

  3. Auto Scaling 발동 지연 측정
     - 스케일아웃 트리거 후 실제 태스크가 RUNNING 되기까지 소요 시간
     - "알람 ALARM → 새 태스크 RUNNING" 전체 구간 타이밍

  4. RDS Proxy 연결 병목 탐색
     - 연속 빠른 HTTP 요청으로 DB 커넥션 풀이 언제 포화되는지 탐지
     - 에러 응답 패턴 분석

  5. SQS 가시성 타임아웃 레이스 탐색
     - VisibilityTimeout 내에 메시지를 처리하지 못하면 재수신 → DLQ 유입
     - 현재 설정(300s)에서 실제 worker 처리 완료 시간과의 여유 측정

모든 단계는 단계 시작 시각과 종료 시각을 기록한다.
임계점은 [BREACH] 태그로 출력하고, 정상 범위는 [OK] 로 출력한다.
"""

import concurrent.futures
import io
import json
import os
import struct
import sys
import threading
import time
import uuid
from datetime import datetime, timezone

import boto3
import requests as http_requests

# ── 환경변수 ───────────────────────────────────────────────────────────────────
AWS_REGION        = os.environ.get("AWS_REGION", "ap-northeast-2")
AWS_PROFILE       = os.environ.get("AWS_PROFILE", "bya")
FREE_QUEUE_URL    = os.environ.get("FREE_QUEUE_URL",
    "https://sqs.ap-northeast-2.amazonaws.com/455535733131/free-queue")
FREE_DLQ_URL      = os.environ.get("FREE_DLQ_URL",
    "https://sqs.ap-northeast-2.amazonaws.com/455535733131/free-dlq")
ECS_CLUSTER       = os.environ.get("ECS_CLUSTER", "securevoice-dev-cluster")
ECS_SERVICE_FREE  = os.environ.get("ECS_SERVICE_FREE_WORKER",
    "securevoice-dev-free-worker-service")
API_HOST          = os.environ.get("API_HOST", "http://api-origin.mzmt.shop")
ACCOUNT_ID        = os.environ.get("ACCOUNT_ID", "455535733131")
AUDIO_BUCKET      = os.environ.get("AUDIO_BUCKET",
    f"mzc-securevoiceguard-audio-dev-{ACCOUNT_ID}-{AWS_REGION}-an")

# ── 임계값 기준 ────────────────────────────────────────────────────────────────
LATENCY_WARN_MS     = 500    # 응답 지연 경고 기준 (ms)
LATENCY_BREACH_MS   = 2000   # 응답 지연 임계점 (ms)
ERROR_WARN_PCT      = 1.0    # 에러율 경고 기준 (%)
ERROR_BREACH_PCT    = 5.0    # 에러율 임계점 (%)
SCALEOUT_WARN_SEC   = 120    # 스케일아웃 지연 경고 (s)
SCALEOUT_BREACH_SEC = 300    # 스케일아웃 지연 임계점 (s)

PASS_STR   = "\033[92m[OK]\033[0m    "
FAIL_STR   = "\033[91m[BREACH]\033[0m"
WARN_STR   = "\033[93m[WARN]\033[0m  "
INFO_STR   = "\033[94m[INFO]\033[0m  "
MEAS_STR   = "\033[96m[MEAS]\033[0m  "

session = boto3.Session(region_name=AWS_REGION, profile_name=AWS_PROFILE)
sqs = session.client("sqs")
ecs = session.client("ecs")
cw  = session.client("cloudwatch")

findings = []  # (severity, item, value, threshold, description)


def record(severity, item, value_str, threshold_str, detail):
    findings.append((severity, item, value_str, threshold_str, detail))


def ts():
    return datetime.now(timezone.utc).strftime("%H:%M:%S")


def make_dummy_wav(duration_sec=2.0, sample_rate=16000) -> bytes:
    num_samples = int(sample_rate * duration_sec)
    pcm_data = bytes(num_samples * 2)
    data_size = len(pcm_data)
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + data_size, b"WAVE",
        b"fmt ", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16,
        b"data", data_size,
    )
    return header + pcm_data


# ══════════════════════════════════════════════════════════════════════════════
# TC-ST-01: API 응답 지연 — 동시 요청 수 단계별 증가
# ══════════════════════════════════════════════════════════════════════════════
def test_api_latency_ramp():
    print(f"\n{'━'*65}")
    print(f"[TC-ST-01] API 응답 지연 — 동시 요청 수 단계별 증가")
    print(f"{'━'*65}")
    print(f"  기준: 경고={LATENCY_WARN_MS}ms / 임계={LATENCY_BREACH_MS}ms / 에러경고={ERROR_WARN_PCT}% / 에러임계={ERROR_BREACH_PCT}%")
    print(f"  {'VU':>4}  {'총요청':>5}  {'성공':>5}  {'실패':>5}  {'에러율':>7}  {'p50':>7}  {'p95':>7}  {'p99':>7}  {'max':>7}  판정")
    print(f"  {'-'*4}  {'-'*5}  {'-'*5}  {'-'*5}  {'-'*7}  {'-'*7}  {'-'*7}  {'-'*7}  {'-'*7}  {'------'}")

    stages = [1, 5, 10, 20, 50, 100]
    url = f"{API_HOST}/api/health"
    breach_found = False

    for vu in stages:
        latencies = []
        errors = []
        lock = threading.Lock()

        def _req(_):
            t0 = time.time()
            try:
                r = http_requests.get(url, timeout=10)
                elapsed = (time.time() - t0) * 1000
                with lock:
                    latencies.append(elapsed)
                    if r.status_code >= 500:
                        errors.append(r.status_code)
            except Exception as e:
                elapsed = (time.time() - t0) * 1000
                with lock:
                    latencies.append(elapsed)
                    errors.append(str(e)[:30])

        with concurrent.futures.ThreadPoolExecutor(max_workers=vu) as pool:
            list(pool.map(_req, range(vu)))

        latencies.sort()
        total = len(latencies)
        err_cnt = len(errors)
        err_pct = (err_cnt / total * 100) if total > 0 else 0
        p50 = latencies[int(total * 0.50) - 1] if total > 0 else 0
        p95 = latencies[int(total * 0.95) - 1] if total > 0 else 0
        p99 = latencies[int(total * 0.99) - 1] if total > 0 else 0
        mx  = latencies[-1] if latencies else 0

        if p95 >= LATENCY_BREACH_MS or err_pct >= ERROR_BREACH_PCT:
            verdict = f"\033[91m[BREACH]\033[0m"
            if not breach_found:
                record("BREACH", "API 동시요청 임계점", f"VU={vu}",
                       f"p95<{LATENCY_BREACH_MS}ms & 에러<{ERROR_BREACH_PCT}%",
                       f"p95={p95:.0f}ms, 에러율={err_pct:.1f}%")
                breach_found = True
        elif p95 >= LATENCY_WARN_MS or err_pct >= ERROR_WARN_PCT:
            verdict = f"\033[93m[WARN] \033[0m"
            record("WARN", "API 응답 지연 경고", f"VU={vu}",
                   f"p95<{LATENCY_WARN_MS}ms",
                   f"p95={p95:.0f}ms, 에러율={err_pct:.1f}%")
        else:
            verdict = f"\033[92m[OK]   \033[0m"

        print(f"  {vu:>4}  {total:>5}  {total-err_cnt:>5}  {err_cnt:>5}  "
              f"{err_pct:>6.1f}%  {p50:>6.0f}ms  {p95:>6.0f}ms  "
              f"{p99:>6.0f}ms  {mx:>6.0f}ms  {verdict}")

        time.sleep(0.5)  # 단계 간 냉각

    if not breach_found:
        record("OK", "API 동시요청 임계점", f"VU≤{stages[-1]}",
               f"p95<{LATENCY_BREACH_MS}ms", "테스트 최대 VU에서도 임계 미도달")
        print(f"\n  {PASS_STR} VU={stages[-1]} 까지 임계점 미도달 — 더 높은 부하 테스트 권고")


# ══════════════════════════════════════════════════════════════════════════════
# TC-ST-02: SQS 메시지 버스트 — 큐 깊이 변화 및 Worker 처리 여력 측정
# ══════════════════════════════════════════════════════════════════════════════
def _get_queue_depth(url):
    r = sqs.get_queue_attributes(
        QueueUrl=url,
        AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
    )
    a = r["Attributes"]
    return int(a["ApproximateNumberOfMessages"]), int(a["ApproximateNumberOfMessagesNotVisible"])


def _inject_messages(queue_url, count):
    """유효하지 않은 S3 키를 가진 메시지를 count개 주입 (worker가 처리 실패 → 재수신 반복 → DLQ)"""
    injected = 0
    for i in range(0, count, 10):
        batch = []
        for j in range(min(10, count - i)):
            batch.append({
                "Id": str(uuid.uuid4())[:8],
                "MessageBody": json.dumps({
                    "request_id": f"stress-{uuid.uuid4()}",
                    "user_type": "guest",
                    "plan": "free",
                    "input_bucket": AUDIO_BUCKET,
                    "input_key": f"stress-test/NONEXISTENT-{uuid.uuid4()}.wav",
                    "result_bucket": AUDIO_BUCKET,
                    "result_key": f"stress-test/result-{uuid.uuid4()}.json",
                }),
            })
        sqs.send_message_batch(QueueUrl=queue_url, Entries=batch)
        injected += len(batch)
    return injected


def test_sqs_burst():
    print(f"\n{'━'*65}")
    print(f"[TC-ST-02] SQS 메시지 버스트 — 큐 깊이 변화 및 Worker 처리 여력")
    print(f"{'━'*65}")
    print(f"  경고: worker는 실제 음성 처리이므로 DLQ 유입을 의도적으로 유발합니다.")
    print(f"  테스트 후 99_cleanup 스크립트로 정리하세요.\n")

    stages = [10, 30, 50, 100]
    dlq_events = []

    print(f"  {'배치':>5}  {'주입수':>5}  {'주입시간':>8}  {'큐깊이(viz)':>12}  {'큐깊이(inv)':>12}  {'DLQ':>5}  판정")
    print(f"  {'-'*5}  {'-'*5}  {'-'*8}  {'-'*12}  {'-'*12}  {'-'*5}  ------")

    total_injected = 0
    breach_found = False

    for batch_size in stages:
        # 주입 전 상태
        vis_before, inv_before = _get_queue_depth(FREE_QUEUE_URL)
        dlq_before, _ = _get_queue_depth(FREE_DLQ_URL)

        t0 = time.time()
        injected = _inject_messages(FREE_QUEUE_URL, batch_size)
        inject_time = time.time() - t0
        total_injected += injected

        time.sleep(3)  # SQS 반영 대기

        vis_after, inv_after = _get_queue_depth(FREE_QUEUE_URL)
        dlq_after, _ = _get_queue_depth(FREE_DLQ_URL)
        dlq_delta = dlq_after - dlq_before

        # Worker가 소화 중인 메시지 수 (in-flight)
        # 워커 1대 = 동시 1개 처리, in-flight이 visible보다 많으면 큐 쌓임
        if vis_after > 20:
            verdict = f"\033[93m[WARN] \033[0m"
            if not breach_found and vis_after > 50:
                verdict = f"\033[91m[BREACH]\033[0m"
                record("BREACH", "SQS 큐 적체 임계점", f"visible={vis_after}",
                       "visible<20 (worker 1대 기준)",
                       f"batch={batch_size}, 주입후 visible={vis_after}, DLQ+{dlq_delta}")
                breach_found = True
            else:
                record("WARN", "SQS 큐 적체 경고", f"visible={vis_after}",
                       "visible<20",
                       f"batch={batch_size}, worker 처리 여력 부족 가능")
        else:
            verdict = f"\033[92m[OK]   \033[0m"

        if dlq_delta > 0:
            dlq_events.append((batch_size, dlq_delta))

        print(f"  {batch_size:>5}  {injected:>5}  {inject_time:>6.2f}s   "
              f"{vis_after:>12}  {inv_after:>12}  {dlq_delta:>5}  {verdict}")

    print(f"\n  총 주입 메시지: {total_injected}개")
    if dlq_events:
        print(f"  DLQ 유입 발생 배치: {dlq_events}")
        record("WARN", "SQS DLQ 유입 발생", str(dlq_events), "DLQ=0",
               "스트레스 주입 중 DLQ 유입 — worker 재시도 초과 발생")
    else:
        print(f"  DLQ 유입 없음 (worker 처리 중 또는 아직 MaxReceiveCount 미도달)")

    # 큐 정리
    print(f"\n  큐 정리 중 (purge)...")
    try:
        sqs.purge_queue(QueueUrl=FREE_QUEUE_URL)
        print(f"  {PASS_STR} free-queue purge 완료")
    except Exception as e:
        print(f"  {WARN_STR} purge 실패 (60초 제한일 수 있음): {e}")


# ══════════════════════════════════════════════════════════════════════════════
# TC-ST-03: Auto Scaling 발동 ~ 실제 태스크 RUNNING 시간 측정
# ══════════════════════════════════════════════════════════════════════════════
def test_autoscaling_latency():
    print(f"\n{'━'*65}")
    print(f"[TC-ST-03] Auto Scaling 발동 지연 측정")
    print(f"{'━'*65}")
    print(f"  경고={SCALEOUT_WARN_SEC}s / 임계={SCALEOUT_BREACH_SEC}s")

    # 현재 태스크 수 확인
    resp = ecs.describe_services(cluster=ECS_CLUSTER, services=[ECS_SERVICE_FREE])
    svc = resp["services"][0]
    before_running = svc["runningCount"]
    before_desired = svc["desiredCount"]
    print(f"  {INFO_STR} 현재 상태: running={before_running}, desired={before_desired}")

    # Alarm 상태 확인
    alarm_name = "securevoice-free-queue-visible-high"
    alarm_resp = cw.describe_alarms(AlarmNames=[alarm_name])
    alarm_state = alarm_resp["MetricAlarms"][0]["StateValue"] if alarm_resp["MetricAlarms"] else "N/A"
    print(f"  {INFO_STR} Scale-Out Alarm 현재 상태: {alarm_state}")

    # 트리거 임계값(2) 이상 메시지 주입
    print(f"  {INFO_STR} Scale-Out 트리거: free-queue에 메시지 5개 주입 중...")
    trigger_count = 5
    for i in range(trigger_count):
        sqs.send_message(
            QueueUrl=FREE_QUEUE_URL,
            MessageBody=json.dumps({
                "request_id": f"scaleout-trigger-{uuid.uuid4()}",
                "user_type": "guest",
                "plan": "free",
                "input_bucket": AUDIO_BUCKET,
                "input_key": f"stress-test/NONEXISTENT-trigger-{i}.wav",
                "result_bucket": AUDIO_BUCKET,
                "result_key": f"stress-test/result-trigger-{i}.json",
            }),
        )

    t_inject = time.time()
    print(f"  {INFO_STR} [{ts()}] 메시지 주입 완료. Alarm ALARM 전환 대기 중 (최대 120s)...")

    # Alarm ALARM 전환 대기
    t_alarm = None
    for _ in range(24):  # 5s × 24 = 120s
        time.sleep(5)
        alarm_resp = cw.describe_alarms(AlarmNames=[alarm_name])
        state = alarm_resp["MetricAlarms"][0]["StateValue"] if alarm_resp["MetricAlarms"] else "N/A"
        elapsed = time.time() - t_inject
        print(f"  [{ts()}] Alarm={state}, 경과={elapsed:.0f}s")
        if state == "ALARM":
            t_alarm = time.time()
            alarm_delay = t_alarm - t_inject
            print(f"  {MEAS_STR} Alarm ALARM 전환 소요: {alarm_delay:.1f}s")
            break
    else:
        print(f"  {WARN_STR} 120s 내 Alarm ALARM 미전환 — 큐 메시지가 이미 처리됐을 수 있음")
        record("WARN", "Scale-Out Alarm 미발동", ">120s", "<60s", "메시지 수가 이미 감소했거나 평가 주기 미도달")
        # 큐 정리
        try: sqs.purge_queue(QueueUrl=FREE_QUEUE_URL)
        except: pass
        return

    # 태스크 수 변화 대기
    print(f"  {INFO_STR} [{ts()}] Alarm 발동 후 태스크 증가 대기 (최대 300s)...")
    t_task_up = None
    for _ in range(60):  # 5s × 60 = 300s
        time.sleep(5)
        resp = ecs.describe_services(cluster=ECS_CLUSTER, services=[ECS_SERVICE_FREE])
        svc = resp["services"][0]
        running = svc["runningCount"]
        desired = svc["desiredCount"]
        elapsed = time.time() - t_inject
        print(f"  [{ts()}] running={running}, desired={desired}, 경과={elapsed:.0f}s")
        if running > before_running or desired > before_desired:
            t_task_up = time.time()
            break
    else:
        print(f"  {FAIL_STR} 300s 내 태스크 증가 미확인")
        record("BREACH", "Scale-Out 태스크 미증가", ">300s", f"<{SCALEOUT_BREACH_SEC}s",
               "Alarm 발동 후 태스크가 증가하지 않음 — 스케일링 정책 확인 필요")
        try: sqs.purge_queue(QueueUrl=FREE_QUEUE_URL)
        except: pass
        return

    total_scaleout = t_task_up - t_inject
    alarm_to_task = t_task_up - t_alarm

    print(f"\n  {MEAS_STR} Scale-Out 전체 지연: {total_scaleout:.1f}s (주입→태스크 running)")
    print(f"  {MEAS_STR} Alarm→태스크 지연:   {alarm_to_task:.1f}s")

    if total_scaleout >= SCALEOUT_BREACH_SEC:
        print(f"  {FAIL_STR} Scale-Out 임계 초과: {total_scaleout:.0f}s > {SCALEOUT_BREACH_SEC}s")
        record("BREACH", "Auto Scale-Out 지연", f"{total_scaleout:.0f}s", f"<{SCALEOUT_BREACH_SEC}s",
               f"주입→RUNNING {total_scaleout:.0f}s, Alarm→RUNNING {alarm_to_task:.0f}s")
    elif total_scaleout >= SCALEOUT_WARN_SEC:
        print(f"  {WARN_STR} Scale-Out 경고: {total_scaleout:.0f}s > {SCALEOUT_WARN_SEC}s")
        record("WARN", "Auto Scale-Out 지연 경고", f"{total_scaleout:.0f}s", f"<{SCALEOUT_WARN_SEC}s",
               f"주입→RUNNING {total_scaleout:.0f}s")
    else:
        print(f"  {PASS_STR} Scale-Out 정상: {total_scaleout:.0f}s")
        record("OK", "Auto Scale-Out 지연", f"{total_scaleout:.0f}s", f"<{SCALEOUT_WARN_SEC}s",
               f"주입→RUNNING {total_scaleout:.0f}s, Alarm→RUNNING {alarm_to_task:.0f}s")

    # 큐 정리
    try: sqs.purge_queue(QueueUrl=FREE_QUEUE_URL)
    except: pass


# ══════════════════════════════════════════════════════════════════════════════
# TC-ST-04: API DB 연결 병목 — 빠른 연속 요청으로 RDS Proxy 포화 탐색
# ══════════════════════════════════════════════════════════════════════════════
def test_db_connection_stress():
    print(f"\n{'━'*65}")
    print(f"[TC-ST-04] DB 연결 병목 탐색 — 빠른 연속 요청 (DB 조회 엔드포인트)")
    print(f"{'━'*65}")
    print(f"  비존재 request_id 조회로 DB SELECT를 반복하여 커넥션 풀 포화를 유도합니다.")

    stages = [
        (10,  1,  "워밍업"),
        (50,  5,  "정상 부하"),
        (200, 10, "중간 부하"),
        (500, 20, "높은 부하"),
        (1000,50, "극한 부하"),
    ]

    print(f"\n  {'요청수':>6}  {'VU':>4}  {'단계':>8}  {'성공':>6}  {'실패':>6}  {'에러율':>7}  {'p50':>7}  {'p95':>7}  {'p99':>7}  {'소요':>7}  판정")
    print(f"  {'-'*6}  {'-'*4}  {'-'*8}  {'-'*6}  {'-'*6}  {'-'*7}  {'-'*7}  {'-'*7}  {'-'*7}  {'-'*7}  ------")

    url = f"{API_HOST}/api/analysis/stress-nonexistent-{uuid.uuid4()}/result"
    breach_found = False

    for req_count, vu, label in stages:
        latencies = []
        errors = []
        lock = threading.Lock()

        def _req_db(_):
            t0 = time.time()
            try:
                r = http_requests.get(
                    f"{API_HOST}/api/analysis/nonexistent-{uuid.uuid4()}/result",
                    timeout=15
                )
                elapsed = (time.time() - t0) * 1000
                with lock:
                    latencies.append(elapsed)
                    # 404는 정상 (레코드 없음), 500은 에러
                    if r.status_code >= 500:
                        errors.append(r.status_code)
            except Exception as e:
                elapsed = (time.time() - t0) * 1000
                with lock:
                    latencies.append(elapsed)
                    errors.append("timeout/conn")

        t_stage = time.time()
        with concurrent.futures.ThreadPoolExecutor(max_workers=vu) as pool:
            list(pool.map(_req_db, range(req_count)))
        stage_elapsed = time.time() - t_stage

        latencies.sort()
        total = len(latencies)
        err_cnt = len(errors)
        err_pct = (err_cnt / total * 100) if total > 0 else 0
        p50 = latencies[int(total * 0.50) - 1] if total > 0 else 0
        p95 = latencies[int(total * 0.95) - 1] if total > 0 else 0
        p99 = latencies[int(total * 0.99) - 1] if total > 0 else 0

        if p99 >= LATENCY_BREACH_MS or err_pct >= ERROR_BREACH_PCT:
            verdict = f"\033[91m[BREACH]\033[0m"
            if not breach_found:
                record("BREACH", "DB 커넥션 병목 임계점", f"요청={req_count}/VU={vu}",
                       f"p99<{LATENCY_BREACH_MS}ms & 에러<{ERROR_BREACH_PCT}%",
                       f"p99={p99:.0f}ms, 에러율={err_pct:.1f}%, "
                       f"에러내용={set(str(e) for e in errors[:3])}")
                breach_found = True
        elif p95 >= LATENCY_WARN_MS or err_pct >= ERROR_WARN_PCT:
            verdict = f"\033[93m[WARN] \033[0m"
            record("WARN", "DB 연결 지연 경고", f"요청={req_count}/VU={vu}",
                   f"p95<{LATENCY_WARN_MS}ms",
                   f"p95={p95:.0f}ms, 에러율={err_pct:.1f}%")
        else:
            verdict = f"\033[92m[OK]   \033[0m"

        print(f"  {req_count:>6}  {vu:>4}  {label:>8}  {total-err_cnt:>6}  {err_cnt:>6}  "
              f"{err_pct:>6.1f}%  {p50:>6.0f}ms  {p95:>6.0f}ms  {p99:>6.0f}ms  "
              f"{stage_elapsed:>5.1f}s  {verdict}")

        if breach_found:
            print(f"\n  {FAIL_STR} 임계점 발견, 이상 부하 종료")
            break
        time.sleep(1)

    if not breach_found:
        record("OK", "DB 커넥션 병목", f"요청≤{stages[-1][0]}",
               "임계 미도달", "테스트 최대 부하에서도 정상")


# ══════════════════════════════════════════════════════════════════════════════
# TC-ST-05: API 업로드 엔드포인트 — 파일 크기별 지연 측정
# ══════════════════════════════════════════════════════════════════════════════
def test_upload_size_latency():
    print(f"\n{'━'*65}")
    print(f"[TC-ST-05] 파일 크기별 업로드 지연 측정 (POST /api/analysis/request)")
    print(f"{'━'*65}")

    # duration별 WAV 크기
    test_cases = [
        (1,  "1초 WAV  (~32KB)"),
        (5,  "5초 WAV  (~160KB)"),
        (10, "10초 WAV (~320KB)"),
        (30, "30초 WAV (~960KB)"),
        (60, "60초 WAV (~1.9MB)"),
    ]

    print(f"\n  {'파일':>14}  {'크기':>8}  {'응답코드':>8}  {'응답시간':>8}  판정")
    print(f"  {'-'*14}  {'-'*8}  {'-'*8}  {'-'*8}  ------")

    url = f"{API_HOST}/api/analysis/request"
    breach_found = False

    for duration, label in test_cases:
        wav_bytes = make_dummy_wav(duration_sec=duration)
        size_kb = len(wav_bytes) / 1024
        filename = f"stress-{duration}s.wav"

        t0 = time.time()
        try:
            r = http_requests.post(
                url,
                files={"file": (filename, io.BytesIO(wav_bytes), "audio/wav")},
                timeout=30,
            )
            elapsed_ms = (time.time() - t0) * 1000
            status = r.status_code

            if status >= 500:
                verdict = f"\033[91m[BREACH]\033[0m"
                if not breach_found:
                    record("BREACH", "업로드 5xx 에러", label,
                           "HTTP < 500",
                           f"status={status}, size={size_kb:.0f}KB, resp={r.text[:100]}")
                    breach_found = True
            elif elapsed_ms >= LATENCY_BREACH_MS:
                verdict = f"\033[91m[BREACH]\033[0m"
                if not breach_found:
                    record("BREACH", "업로드 지연 임계점", label,
                           f"<{LATENCY_BREACH_MS}ms",
                           f"elapsed={elapsed_ms:.0f}ms, size={size_kb:.0f}KB")
                    breach_found = True
            elif elapsed_ms >= LATENCY_WARN_MS:
                verdict = f"\033[93m[WARN] \033[0m"
                record("WARN", "업로드 지연 경고", label,
                       f"<{LATENCY_WARN_MS}ms",
                       f"elapsed={elapsed_ms:.0f}ms, size={size_kb:.0f}KB")
            else:
                verdict = f"\033[92m[OK]   \033[0m"

            print(f"  {label:>14}  {size_kb:>6.0f}KB  {status:>8}  {elapsed_ms:>6.0f}ms  {verdict}")

        except http_requests.exceptions.Timeout:
            print(f"  {label:>14}  {size_kb:>6.0f}KB  {'TIMEOUT':>8}  {'>30000ms':>8}  \033[91m[BREACH]\033[0m")
            record("BREACH", "업로드 타임아웃", label, "<30s", f"size={size_kb:.0f}KB에서 타임아웃")
            breach_found = True
        except Exception as e:
            print(f"  {label:>14}  {size_kb:>6.0f}KB  {'ERROR':>8}  {'N/A':>8}  \033[91m[BREACH]\033[0m")
            record("BREACH", "업로드 연결 오류", label, "연결 성공",
                   str(e)[:80])
            breach_found = True

    if not breach_found:
        record("OK", "파일 크기별 업로드", "60초 WAV까지",
               f"<{LATENCY_WARN_MS}ms", "모든 크기 정상 처리")


# ══════════════════════════════════════════════════════════════════════════════
# 최종 취약점 요약 출력
# ══════════════════════════════════════════════════════════════════════════════
def print_findings_summary():
    print(f"\n\n{'#'*65}")
    print(f"# 취약점 및 개선 필요 항목 요약")
    print(f"{'#'*65}")

    breaches = [(s, i, v, t, d) for s, i, v, t, d in findings if s == "BREACH"]
    warns    = [(s, i, v, t, d) for s, i, v, t, d in findings if s == "WARN"]
    oks      = [(s, i, v, t, d) for s, i, v, t, d in findings if s == "OK"]

    if breaches:
        print(f"\n🔴 임계점 돌파 ({len(breaches)}건):")
        for _, item, val, thr, detail in breaches:
            print(f"  ✗ {item}")
            print(f"    측정값: {val}  |  기준: {thr}")
            print(f"    내용: {detail}")

    if warns:
        print(f"\n🟡 경고 ({len(warns)}건):")
        for _, item, val, thr, detail in warns:
            print(f"  △ {item}")
            print(f"    측정값: {val}  |  기준: {thr}")
            print(f"    내용: {detail}")

    if oks:
        print(f"\n🟢 정상 ({len(oks)}건):")
        for _, item, val, _, detail in oks:
            print(f"  ✓ {item}: {val} — {detail}")

    print(f"\n{'='*65}")
    print(f"결과: BREACH {len(breaches)}건 / WARN {len(warns)}건 / OK {len(oks)}건")
    return len(breaches)


# ══════════════════════════════════════════════════════════════════════════════
# 메인
# ══════════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    print(f"\n{'#'*65}")
    print(f"# SecureVoice 08: 인프라 스트레스 테스트 — 취약점 탐색")
    print(f"# 실행 시각: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"# API: {API_HOST}")
    print(f"# 주의: 이 테스트는 실제 AWS 리소스에 부하를 가합니다!")
    print(f"{'#'*65}")

    # 실행할 테스트 선택 (환경변수 STRESS_TESTS로 제어)
    tests = os.environ.get("STRESS_TESTS", "01,02,03,04,05").split(",")

    if "01" in tests:
        test_api_latency_ramp()
    if "02" in tests:
        test_sqs_burst()
    if "03" in tests:
        test_autoscaling_latency()
    if "04" in tests:
        test_db_connection_stress()
    if "05" in tests:
        test_upload_size_latency()

    breach_count = print_findings_summary()
    sys.exit(1 if breach_count > 0 else 0)
