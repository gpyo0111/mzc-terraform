"""
SecureVoice API 부하테스트 - Locust

시나리오:
  1. HealthCheck        (weight=1)  - /api/health 폴링
  2. GuestAnalysis      (weight=6)  - 비로그인 사용자 음성 분석 요청 (POST /api/analysis/request)
  3. PollResult         (weight=6)  - 분석 결과 조회 (GET /api/analysis/{id}/result)
  4. RegisterAndAnalyze (weight=2)  - 회원가입 → 로그인 → 분석 요청 전체 플로우

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
from locust import TaskSet

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


# ── 공통 헬퍼 ─────────────────────────────────────────────────────────────────
def _random_email() -> str:
    return f"loadtest-{uuid.uuid4().hex[:8]}@example.com"


# ── User 클래스 ───────────────────────────────────────────────────────────────

class GuestUser(HttpUser):
    """
    비로그인 사용자: 음성 업로드 → 결과 폴링 반복
    실제 트래픽의 대부분을 차지하는 패턴을 모방
    """
    weight       = 7
    wait_time    = between(1, 3)
    host         = TARGET_HOST

    # 이 유저가 이전에 요청한 request_id 들 (결과 폴링에 사용)
    _pending_ids: list[str]

    def on_start(self):
        self._pending_ids = []

    @task(6)
    def upload_and_request(self):
        """POST /api/analysis/request — 음성 파일 업로드 후 분석 요청"""
        audio = _get_audio_bytes()
        filename = f"sample-{uuid.uuid4().hex[:8]}.wav"

        with self.client.post(
            "/api/analysis/request",
            files={"file": (filename, io.BytesIO(audio), "audio/wav")},
            name="/api/analysis/request",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                data = resp.json()
                req_id = data.get("request_id")
                if req_id:
                    self._pending_ids.append(req_id)
                    # 목록이 너무 길어지지 않도록 최근 10개만 유지
                    self._pending_ids = self._pending_ids[-10:]
                resp.success()
            else:
                resp.failure(f"upload failed: {resp.status_code} {resp.text[:200]}")

    @task(4)
    def poll_result(self):
        """GET /api/analysis/{id}/result — 분석 결과 조회"""
        if not self._pending_ids:
            return

        req_id = random.choice(self._pending_ids)
        with self.client.get(
            f"/api/analysis/{req_id}/result",
            name="/api/analysis/{id}/result",
            catch_response=True,
        ) as resp:
            if resp.status_code in (200, 404):
                resp.success()
            else:
                resp.failure(f"poll failed: {resp.status_code}")

    @task(1)
    def health_check(self):
        """GET /api/health"""
        self.client.get("/api/health", name="/api/health")


class AuthenticatedUser(HttpUser):
    """
    로그인 사용자: 회원가입 → 로그인 → 분석 요청 → 결과 조회 → 내 요청 목록
    유료/무료 사용자 플로우를 모방
    """
    weight    = 3
    wait_time = between(2, 5)
    host      = TARGET_HOST

    _token: str | None
    _pending_ids: list[str]

    def on_start(self):
        self._token      = None
        self._pending_ids = []
        self._register_and_login()

    def _auth_headers(self) -> dict:
        if self._token:
            return {"Authorization": f"Bearer {self._token}"}
        return {}

    def _register_and_login(self):
        email    = _random_email()
        password = "LoadTest1234!"
        name     = f"LT-{uuid.uuid4().hex[:6]}"

        # 회원가입
        resp = self.client.post(
            "/api/auth/register",
            json={"email": email, "password": password, "display_name": name},
            name="/api/auth/register",
        )
        if resp.status_code not in (200, 201):
            logger.debug(f"[register] {resp.status_code} {resp.text[:100]}")
            return

        # 로그인
        resp = self.client.post(
            "/api/auth/login",
            json={"email": email, "password": password},
            name="/api/auth/login",
        )
        if resp.status_code == 200:
            self._token = resp.json().get("access_token")
        else:
            logger.debug(f"[login] {resp.status_code} {resp.text[:100]}")

    @task(5)
    def authenticated_upload(self):
        """인증된 분석 요청"""
        audio    = _get_audio_bytes()
        filename = f"auth-sample-{uuid.uuid4().hex[:8]}.wav"

        with self.client.post(
            "/api/analysis/request",
            files={"file": (filename, io.BytesIO(audio), "audio/wav")},
            headers=self._auth_headers(),
            name="/api/analysis/request [auth]",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                req_id = resp.json().get("request_id")
                if req_id:
                    self._pending_ids = (self._pending_ids + [req_id])[-10:]
                resp.success()
            else:
                resp.failure(f"{resp.status_code}")

    @task(3)
    def poll_result(self):
        if not self._pending_ids:
            return
        req_id = random.choice(self._pending_ids)
        with self.client.get(
            f"/api/analysis/{req_id}/result",
            headers=self._auth_headers(),
            name="/api/analysis/{id}/result [auth]",
            catch_response=True,
        ) as resp:
            if resp.status_code in (200, 404):
                resp.success()
            else:
                resp.failure(f"{resp.status_code}")

    @task(2)
    def list_my_requests(self):
        """GET /api/requests — 내 분석 기록"""
        with self.client.get(
            "/api/requests",
            headers=self._auth_headers(),
            name="/api/requests",
            catch_response=True,
        ) as resp:
            if resp.status_code in (200, 401):
                resp.success()
            else:
                resp.failure(f"{resp.status_code}")

    @task(1)
    def health_check(self):
        self.client.get("/api/health", name="/api/health")
