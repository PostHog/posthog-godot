#!/usr/bin/env python3
"""Run headless tests against a loopback-only PostHog HTTP fixture."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append((self.path, body, self.headers.get("Content-Type")))
        if self.path == "/flags/?v=2":
            response = {
                "flags": {
                    "http-flag": {
                        "enabled": True,
                        "metadata": {"payload": '{"transport":"http"}'},
                    }
                }
            }
        elif self.path == "/batch/":
            response = {"status": 1}
        else:
            self.send_error(404)
            return
        payload = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    godot = os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4")
    if not godot and Path("/Applications/Godot.app/Contents/MacOS/Godot").exists():
        godot = "/Applications/Godot.app/Contents/MacOS/Godot"
    if not godot:
        raise SystemExit("Godot 4.5+ required. Set GODOT to the executable path.")
    imported = subprocess.run(
        [godot, "--headless", "--path", str(ROOT), "--editor", "--import", "--quit"],
        capture_output=True,
        text=True,
        timeout=120,
    )
    print(imported.stdout + imported.stderr)
    if imported.returncode or "ERROR:" in imported.stdout + imported.stderr:
        return 1
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = dict(
                os.environ, POSTHOG_TEST_HOST=f"http://127.0.0.1:{server.server_port}"
            )
            result = subprocess.run(
                [
                    godot,
                    "--headless",
                    "--path",
                    str(ROOT),
                    "--script",
                    "res://tests/test_sdk.gd",
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=90,
            )
            print(result.stdout + result.stderr)
        finally:
            server.shutdown()
            thread.join()
    output = result.stdout + result.stderr
    if result.returncode:
        return result.returncode
    if any(
        marker in output
        for marker in ["SCRIPT ERROR:", "instances leaked", "still in use at exit"]
    ):
        return 1
    expected_errors = {"ERROR: Expected PostHog automatic error capture test"}
    if any(
        line.startswith("ERROR:") and line not in expected_errors
        for line in output.splitlines()
    ):
        return 1
    if "0 failures" not in output:
        return 1
    batches = [body for path, body, _ in requests if path == "/batch/"]
    flags = [body for path, body, _ in requests if path == "/flags/?v=2"]
    assert len(batches) == 1 and len(flags) == 1, requests
    assert all(content_type == "application/json" for _, _, content_type in requests)
    assert batches[0]["api_key"] == "phc_test"
    event = batches[0]["batch"][0]
    assert event["event"] == "http-integration"
    assert event["properties"]["unicode"] == "Hedgehog 🦔"
    assert event["distinct_id"] == flags[0]["distinct_id"]
    assert flags[0]["$anon_distinct_id"] == event["distinct_id"]
    print("HTTP wire assertions passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
