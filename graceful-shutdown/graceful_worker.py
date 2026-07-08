import sys
import os
import signal
import traceback

# 1. Register signal handlers as early as possible
shutdown_requested = False

def handle_shutdown(signum, frame):
    global shutdown_requested
    print(f"[GRACEFUL] Signal {signum} received. Requesting graceful shutdown...", flush=True)
    shutdown_requested = True

signal.signal(signal.SIGTERM, handle_shutdown)
signal.signal(signal.SIGINT, handle_shutdown)

# 2. Monkey-patch SQSClient.receive_messages
try:
    from sqs_client import SQSClient
    
    orig_receive_messages = SQSClient.receive_messages

    def patched_receive_messages(self, max_number=1, wait_time=20, visibility_timeout=300):
        if shutdown_requested:
            print("[GRACEFUL] Shutdown requested before receive_messages. Exiting worker gracefully.", flush=True)
            sys.exit(0)
        
        try:
            messages = orig_receive_messages(self, max_number, wait_time, visibility_timeout)
        except Exception as e:
            if shutdown_requested:
                print(f"[GRACEFUL] Interrupted by signal during receive_messages: {e}. Exiting worker gracefully.", flush=True)
                sys.exit(0)
            raise e

        if shutdown_requested and not messages:
            print("[GRACEFUL] Shutdown requested and no messages received. Exiting worker gracefully.", flush=True)
            sys.exit(0)
            
        return messages

    SQSClient.receive_messages = patched_receive_messages
    print("[GRACEFUL] Successfully monkeypatched SQSClient.receive_messages", flush=True)

except Exception as e:
    print(f"[GRACEFUL] Failed to patch SQSClient: {e}", flush=True)
    traceback.print_exc()

# 3. Import the original worker module and run it
import worker

class PoisonPillError(Exception):
    pass

worker.PoisonPillError = PoisonPillError

def patched_run_aws():
    from db_client import DBClient
    from s3_client import S3Client
    from sqs_client import SQSClient
    import json
    import traceback

    print(f"[WORKER] started aws mode queue_type={worker.QUEUE_TYPE} (Graceful & Poison Pill Patched Wrapper)", flush=True)

    inferencer = worker.build_inferencer()
    s3_client = S3Client()
    sqs_client = SQSClient()
    db_client = DBClient()

    while True:
        messages = sqs_client.receive_messages(max_number=1, wait_time=20, visibility_timeout=300)

        if not messages:
            continue

        for sqs_message in messages:
            receipt_handle = sqs_message["ReceiptHandle"]
            request_id = "unknown"

            try:
                # 1. JSON 파싱
                try:
                    body = sqs_client.parse_body(sqs_message)
                except Exception as e:
                    raise PoisonPillError(f"invalid json: {e}")

                # 2. 유효성 검증
                try:
                    worker.validate_message(body)
                except Exception as e:
                    raise PoisonPillError(f"validation failed: {e}")

                request_id = body.get("request_id", "unknown")
                worker.log(request_id, "sqs message received")

                # 3. 비즈니스 처리 (여기서 발생한 에러는 재시도 대상)
                output = worker.process_message(
                    body,
                    inferencer,
                    s3_client=s3_client,
                    db_client=db_client,
                )

                print(json.dumps(output, ensure_ascii=False), flush=True)
                sqs_client.delete_message(receipt_handle)
                worker.log(request_id, "sqs message deleted")

            except PoisonPillError as e:
                print(f"[WORKER][POISON][{request_id}] {e}", flush=True)
                try:
                    sqs_client.delete_message(receipt_handle)
                except Exception as delete_err:
                    print(f"[WORKER][POISON][ERROR] Failed to delete poison pill message: {delete_err}", flush=True)
            except Exception:
                print(f"[WORKER][ERROR][{request_id}]", flush=True)
                print(traceback.format_exc(), flush=True)

worker.run_aws = patched_run_aws

if __name__ == "__main__":
    worker.start_metrics_server_if_enabled()

    print(f"[WORKER] entrypoint WORKER_MODE={worker.WORKER_MODE} (Graceful Wrapper)", flush=True)

    if worker.is_mock_mode():
        worker.run_mock()
    else:
        worker.run_aws()

