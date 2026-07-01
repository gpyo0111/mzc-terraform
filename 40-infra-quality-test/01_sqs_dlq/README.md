# SQS DLQ 격리 & 재처리

> **검증 항목:** 2026-01-01 ~ 2026-01-09 | **협업:** 단독

---

## 실행 순서

```bash
cd scenarios/01_sqs_dlq
bash cli/00_preflight.sh      # 사전 조건 체크 (필수)
bash cli/01_inject_broken.sh
bash cli/02_redrive.sh
bash cli/99_cleanup.sh
```

---

## CLI 파일 설명

| 파일 | 역할 |
|---|---|
| `00_preflight.sh` | 사전 조건 — SQS/DLQ 접근, 워커 RUNNING, Alarm 존재 확인 |
| `01_inject_broken.sh` | 불량 메시지 주입 → MaxReceiveCount 초과 → DLQ 이관 자동 감지 |
| `02_redrive.sh` | DLQ Redrive → 원본 큐 복귀 확인 |
| `99_cleanup.sh` | SQS/DLQ purge |

---

## 합격 기준

```
DLQ 이관 60초 이내 / Alarm 60초 이내 ALARM / Redrive 30초 이내 / 멱등성 DB row=1
```

---

## 결과 기록

```bash
vi results/result_template.md
```
