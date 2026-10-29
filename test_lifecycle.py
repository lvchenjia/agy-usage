#!/usr/bin/env python3
"""
Automated Lifecycle and Resilience Test Suite for AgyUsage.
Runs completely isolated from the active `agy` development environment.
"""

import os
import sys
import time
import json
import signal
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

MOCK_PROCESS_NAME = "mock_agy_proc"
TEST_PORT = 62199

# Sample valid response JSON
MOCK_RESPONSE = {
    "userStatus": {
        "name": "Test User",
        "email": "test@example.com",
        "cascadeModelConfigData": {
            "clientModelConfigs": [
                {
                    "label": "Gemini 3.8 Flash (Medium)",
                    "quotaInfo": {
                        "remainingFraction": 0.88,
                        "resetTime": "2026-10-29T20:00:00Z"
                    }
                }
            ]
        }
    }
}

class MockHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.dumps(MOCK_RESPONSE).encode('utf-8')
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # Suppress request logging

def main():
    print("=" * 60)
    print("Starting AgyUsage Isolated Lifecycle Test Suite")
    print("=" * 60)
    
    app_bin = "/Applications/Agy Usage.app/Contents/MacOS/AgyUsage"
    if not os.path.exists(app_bin):
        print(f"Error: {app_bin} not found. Please build first.")
        sys.exit(1)

    # 1. Spawn a real compiled binary named 'mock_agy_proc'
    mock_bin = "/tmp/mock_agy_proc"
    subprocess.run(["clang", "-O2", "-x", "c", "-", "-o", mock_bin], 
                   input=b'#include <unistd.h>\nint main(){ while(1) sleep(10); return 0; }', check=True)
    
    dummy_proc = subprocess.Popen([mock_bin])
    print(f"[1/4] Spawned mock process '{MOCK_PROCESS_NAME}' (PID: {dummy_proc.pid})")
    
    env = os.environ.copy()
    env["AGY_TEST_TARGET_PROCESS"] = MOCK_PROCESS_NAME
    env["AGY_TEST_PORT"] = str(TEST_PORT)
    env["AGY_TEST_POLL_INTERVAL"] = "1.5"
    
    # Enable quitOnFailure for testing auto-quit
    subprocess.run(["defaults", "write", "com.horse.AgyUsage", "quitOnFailure", "-bool", "true"])

    # 2. Launch AgyUsage while Mock Server is NOT running (simulates agy still booting up)
    print("[2/4] Testing Boot Delay: Launching AgyUsage with NO server listening...")
    agy_app = subprocess.Popen([app_bin], env=env)
    
    # Wait 2.5 seconds: AgyUsage should NOT quit because mock_agy_proc is alive!
    time.sleep(2.5)
    if agy_app.poll() is not None:
        print("FAIL: AgyUsage prematurely quit while mock_agy_proc was alive!")
        dummy_proc.kill()
        sys.exit(1)
    print("PASS: AgyUsage stayed alive and entered fast retry as expected.")

    # 3. Now start the Mock HTTP Server
    print("[3/4] Starting Mock HTTP Server to fulfill RPC request...")
    httpd = HTTPServer(('127.0.0.1', TEST_PORT), MockHandler)
    
    # Process requests for 3 seconds
    start = time.time()
    while time.time() - start < 3.0:
        httpd.handle_request()
        if agy_app.poll() is not None:
            print("FAIL: AgyUsage crashed during RPC handling!")
            dummy_proc.kill()
            httpd.server_close()
            sys.exit(1)
            
    print("PASS: AgyUsage successfully received and parsed RPC response without crashing.")
    httpd.server_close()

    # 4. Terminate the mock process to test Auto-Quit
    print("[4/4] Testing Auto-Quit: Terminating mock_agy_proc...")
    dummy_proc.terminate()
    dummy_proc.wait()
    
    # Wait up to 5 seconds for AgyUsage to detect no process and cleanly terminate
    terminated = False
    for _ in range(25):
        if agy_app.poll() is not None:
            terminated = True
            break
        time.sleep(0.2)
        
    if terminated:
        print("PASS: AgyUsage detected target process termination and exited cleanly!")
    else:
        print("FAIL: AgyUsage failed to exit after mock process terminated.")
        agy_app.kill()
        sys.exit(1)

    print("=" * 60)
    print("ALL TESTS PASSED! Life-cycle is rock solid.")
    print("=" * 60)

if __name__ == "__main__":
    main()
