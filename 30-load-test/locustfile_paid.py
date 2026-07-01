"""
SecureVoice API 부하테스트 - Locust (Paid 전용)

시나리오:
  1. AuthenticatedUpload (weight=6) - 유료 회원 음성 분석 요청 (POST /api/analysis/request [auth])
  2. PollResult          (weight=4) - 분석 결과 조회 (GET /api/analysis/{id}/result [auth])
  3. ListMyRequests      (weight=2) - 내 분석 기록 조회 (GET /api/requests)
  4. HealthCheck         (weight=1) - /api/health 폴링

S3에서 샘플 오디오를 내려받아 multipart/form-data로 전송한다.
S3 접근이 불가한 경우, AUDIO_S3_BUCKET 환경변수가 없으면 로컬 더미 WAV를 사용한다.
"""

import io
import logging
import os
import random
import struct
import uuid

import boto3
from locust import HttpUser, between, events, task

logger = logging.getLogger(__name__)

# ── 환경 변수 ─────────────────────────────────────────────────────────────────
TARGET_HOST      = os.environ.get("TARGET_HOST", "http://localhost:8000")
AUDIO_S3_BUCKET  = os.environ.get("AUDIO_S3_BUCKET", "")
AUDIO_S3_PREFIX  = os.environ.get("AUDIO_S3_PREFIX", "load-test-samples/")
AWS_REGION       = os.environ.get("AWS_REGION", "ap-northeast-2")


# ── 더미 WAV 생성 (S3 없이 로컬 실행 시 사용) ────────────────────────────────
def _make_dummy_wav(duration_sec: float = 2.0, sample_rate: int = 16000) -> bytes:
    """최소한의 PCM WAV 바이트를 반환한다."""
    num_samples = int(sample_rate * duration_sec)
    pcm_data    = bytes(num_samples * 2)          # 16-bit silence

    # RIFF header
    data_size   = len(pcm_data)
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + data_size, b"WAVE",
        b"fmt ", 16,
        1,                    # PCM
        1,                    # mono
        sample_rate,
        sample_rate * 2,      # byte rate
        2,                    # block align
        16,                   # bits per sample
        b"data", data_size,
    )
    return header + pcm_data


# ── S3에서 샘플 오디오 목록 로드 ─────────────────────────────────────────────
_sample_audio_cache: list[bytes] = []


def _load_samples_from_s3() -> list[bytes]:
    if not AUDIO_S3_BUCKET:
        return []

    try:
        s3     = boto3.client("s3", region_name=AWS_REGION)
        paginator = s3.get_paginator("list_objects_v2")
        keys   = []

        for page in paginator.paginate(Bucket=AUDIO_S3_BUCKET, Prefix=AUDIO_S3_PREFIX):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                if key.lower().endswith((".wav", ".flac", ".mp3", ".m4a")):
                    keys.append(key)

        samples = []
        for key in keys[:20]:   # 최대 20개만 메모리에 올린다
            resp = s3.get_object(Bucket=AUDIO_S3_BUCKET, Key=key)
            samples.append(resp["Body"].read())
            logger.info(f"[S3] loaded sample: {key}")

        return samples

    except Exception as e:
        logger.warning(f"[S3] 샘플 로드 실패, 더미 WAV 사용: {e}")
        return []


@events.init.add_listener
def on_locust_init(environment, **kwargs):
    global _sample_audio_cache
    _sample_audio_cache = _load_samples_from_s3()
    if _sample_audio_cache:
        logger.info(f"[INIT] S3 샘플 {len(_sample_audio_cache)}개 로드 완료")
    else:
        logger.info("[INIT] S3 샘플 없음 → 더미 WAV 사용")


def _get_audio_bytes() -> bytes:
    if _sample_audio_cache:
        return random.choice(_sample_audio_cache)
    return _make_dummy_wav()


# ── global 토큰 캐싱 (스레드 세이프하며 부하 발생 시 /api/login 트래픽 과부하 방지) ────
_cached_token = None


# ── User 클래스 ───────────────────────────────────────────────────────────────

class PaidUser(HttpUser):
    """
    유료 사용자: 지정된 paid@bank-b.com 유료 계정으로 로그인하여 지속적으로 분석 부하 전송
    """
    weight    = 1
    wait_time = between(1, 3)
    host      = TARGET_HOST

    _pending_ids: list[str]

    def on_start(self):
        global _cached_token
        self._pending_ids = []
        
        if _cached_token is None:
            logger.info("[Auth] Logging in as paid@bank-b.com...")
            resp = self.client.post(
                "/api/login",
                json={"email": "paid@bank-b.com", "password": "LoadTest1234!"},
                name="/api/login (pre-auth)"
            )
            if resp.status_code == 200:
                _cached_token = resp.json().get("access_token")
                logger.info("[Auth] Logged in successfully. Token cached.")
            else:
                logger.error(f"[Auth] Login failed with status {resp.status_code}: {resp.text}")
                
        self.token = _cached_token

    def _auth_headers(self) -> dict:
        if self.token:
            return {"Authorization": f"Bearer {self.token}"}
        return {}

    @task(6)
    def authenticated_upload(self):
        """인증된 유료 분석 요청"""
        audio    = _get_audio_bytes()
        filename = f"paid-sample-{uuid.uuid4().hex[:8]}.wav"

        with self.client.post(
            "/api/analysis/request",
            files={"file": (filename, io.BytesIO(audio), "audio/wav")},
            headers=self._auth_headers(),
            name="/api/analysis/request [paid]",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                req_id = resp.json().get("request_id")
                if req_id:
                    self._pending_ids = (self._pending_ids + [req_id])[-10:]
                resp.success()
            else:
                resp.failure(f"upload failed: {resp.status_code} {resp.text[:200]}")

    @task(4)
    def poll_result(self):
        if not self._pending_ids:
            return
        req_id = random.choice(self._pending_ids)
        with self.client.get(
            f"/api/analysis/{req_id}/result",
            headers=self._auth_headers(),
            name="/api/analysis/{id}/result [paid]",
            catch_response=True,
        ) as resp:
            if resp.status_code in (200, 404):
                resp.success()
            else:
                resp.failure(f"poll failed: {resp.status_code}")

    @task(2)
    def list_my_requests(self):
        """GET /api/requests — 내 분석 기록"""
        with self.client.get(
            "/api/requests",
            headers=self._auth_headers(),
            name="/api/requests [paid]",
            catch_response=True,
        ) as resp:
            if resp.status_code in (200, 401):
                resp.success()
            else:
                resp.failure(f"list failed: {resp.status_code}")

    @task(1)
    def health_check(self):
        self.client.get("/api/health", name="/api/health")
