FROM python:3.11-slim

WORKDIR /locust

# 시스템 의존성 (boto3 빌드 등)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Python 패키지
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Locust 스크립트
COPY locustfile.py .

# Locust 기본 포트
#   8089 : Web UI
#   5557 : master ↔ worker gRPC (workers connect here)
#   5558 : master ↔ worker gRPC (master connects back)
EXPOSE 8089 5557 5558

ENTRYPOINT ["locust", "-f", "/locust/locustfile.py"]
