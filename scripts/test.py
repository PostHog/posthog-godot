#!/usr/bin/env python3
"""Run headless tests against a loopback-only PostHog HTTP fixture."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import test_editor
import test_package

ROOT = Path(__file__).resolve().parents[1]
requests = []


def reject_non_finite(value):
    raise ValueError(f"Invalid JSON numeric token: {value}")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(
            self.rfile.read(int(self.headers["Content-Length"])),
            parse_constant=reject_non_finite,
        )
        requests.append((self.path, body, dict(self.headers)))
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
            quit_result = subprocess.run(
                [
                    godot,
                    "--headless",
                    "--path",
                    str(ROOT),
                    "--script",
                    "res://tests/test_error_quit.gd",
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=15,
            )
            print(quit_result.stdout + quit_result.stderr)
        finally:
            server.shutdown()
            thread.join()
    output = result.stdout + result.stderr + quit_result.stdout + quit_result.stderr
    if quit_result.returncode:
        return quit_result.returncode
    if result.returncode:
        return result.returncode
    if any(
        marker in output
        for marker in ["SCRIPT ERROR:", "instances leaked", "still in use at exit"]
    ):
        return 1
    expected_errors = {
        "ERROR: Expected PostHog automatic error capture test",
        "ERROR: Expected PostHog forwarding error",
    }
    if any(
        line.startswith("ERROR:") and line not in expected_errors
        for line in output.splitlines()
    ):
        return 1
    if "0 failures" not in output:
        return 1
    batches = [body for path, body, _ in requests if path == "/batch/"]
    flags = [body for path, body, _ in requests if path == "/flags/?v=2"]
    assert len(batches) == 2 and len(flags) == 1, requests
    quit_event = batches[1]["batch"][0]
    assert quit_event["event"] == "$exception"
    assert quit_event["properties"]["$exception_message"] == "quit-error"
    assert all(
        headers.get("Content-Type") == "application/json" for _, _, headers in requests
    )
    assert batches[0]["api_key"] == "phc_test"
    event = batches[0]["batch"][0]
    expected_user_agent = f"posthog-godot/{event['properties']['$lib_version']}"
    assert all(
        headers.get("User-Agent") == expected_user_agent for _, _, headers in requests
    ), requests
    assert event["event"] == "http-integration"
    assert event["properties"]["unicode"] == "Hedgehog 🦔"
    assert event["distinct_id"] == flags[0]["distinct_id"]
    assert flags[0]["$anon_distinct_id"] == event["distinct_id"]
    events = batches[0]["batch"]
    assert [event["event"] for event in events] == [
        "http-integration",
        *[
            f"non-finite-{source}-{index}"
            for source in ("capture", "hook")
            for index in range(3)
        ],
        "finite-neighbor",
    ]
    for event in events[1:-1]:
        properties = event["properties"]
        assert properties["number"] is None
        assert properties["nested"] == {"number": None, "sibling": 42}
        assert properties["items"] == [
            1,
            None,
            {"number": None, "sibling": True},
            [None],
            2,
        ]
        assert properties["typed_items"] == [None, 1.5]
        assert properties["finite"] == 1.5
        assert properties["zero"] == 0
        assert properties["enabled"] is False
        assert "existing_null" in properties and properties["existing_null"] is None
        assert properties["literals"] == ["NaN", "Infinity", "-Infinity"]
    assert events[-1]["properties"]["finite"] == 2.5
    print("HTTP wire assertions passed")
    test_editor.run(godot)
    test_package.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
