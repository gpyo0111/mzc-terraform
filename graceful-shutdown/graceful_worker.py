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

if __name__ == "__main__":
    worker.start_metrics_server_if_enabled()

    print(f"[WORKER] entrypoint WORKER_MODE={worker.WORKER_MODE} (Graceful Wrapper)", flush=True)

    if worker.is_mock_mode():
        worker.run_mock()
    else:
        worker.run_aws()
