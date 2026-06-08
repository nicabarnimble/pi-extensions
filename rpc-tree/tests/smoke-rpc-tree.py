#!/usr/bin/env python3
"""Smoke tests for the rpc-tree Pi extension.

The tests exercise the public RPC contract by spawning `pi --mode rpc` and
inspecting `rpc-tree:event ...` notifications.
"""

from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable

EXTENSION_PATH = Path(__file__).resolve().parents[1] / "index.ts"
EVENT_PREFIX = "rpc-tree:event "


def rpc_process(extra_args: list[str] | None = None) -> subprocess.Popen[str]:
    args = [
        "pi",
        "--mode",
        "rpc",
        "--extension",
        str(EXTENSION_PATH),
        *(extra_args or []),
    ]
    return subprocess.Popen(
        args,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=str(Path(__file__).resolve().parents[2]),
    )


def send(proc: subprocess.Popen[str], obj: dict[str, Any]) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()


def run_until(
    proc: subprocess.Popen[str],
    request_id: str | None = None,
    timeout: float = 10,
    on_event: Callable[[dict[str, Any], subprocess.Popen[str]], None] | None = None,
) -> list[dict[str, Any]]:
    assert proc.stdout is not None
    assert proc.stderr is not None
    deadline = time.time() + timeout
    events: list[dict[str, Any]] = []
    while time.time() < deadline:
        ready, _, _ = select.select([proc.stdout, proc.stderr], [], [], 0.2)
        for stream in ready:
            line = stream.readline()
            if not line:
                continue
            if stream is proc.stdout:
                obj = json.loads(line)
                events.append(obj)
                if on_event:
                    on_event(obj, proc)
                if request_id and obj.get("type") == "response" and obj.get("id") == request_id:
                    return events
            else:
                events.append({"stderr": line.rstrip()})
    raise AssertionError(f"Timed out waiting for {request_id!r}; events={events!r}")


def payloads(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for event in events:
        if event.get("type") == "extension_ui_request" and event.get("method") == "notify":
            message = event.get("message", "")
            if isinstance(message, str) and message.startswith(EVENT_PREFIX):
                out.append(json.loads(message[len(EVENT_PREFIX) :]))
    return out


def run_until_payload(
    proc: subprocess.Popen[str],
    timeout: float = 10,
    on_event: Callable[[dict[str, Any], subprocess.Popen[str]], None] | None = None,
) -> list[dict[str, Any]]:
    assert proc.stdout is not None
    assert proc.stderr is not None
    deadline = time.time() + timeout
    events: list[dict[str, Any]] = []
    while time.time() < deadline:
        ready, _, _ = select.select([proc.stdout, proc.stderr], [], [], 0.2)
        for stream in ready:
            line = stream.readline()
            if not line:
                continue
            if stream is proc.stdout:
                obj = json.loads(line)
                events.append(obj)
                if on_event:
                    on_event(obj, proc)
                if payloads(events):
                    return events
            else:
                events.append({"stderr": line.rstrip()})
    raise AssertionError(f"Timed out waiting for rpc-tree:event; events={events!r}")


def stop(proc: subprocess.Popen[str]) -> None:
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()


def latest_payload(events: list[dict[str, Any]]) -> dict[str, Any]:
    found = payloads(events)
    if not found:
        raise AssertionError(f"No rpc-tree payload in events: {events!r}")
    return found[-1]


def discover_command(proc: subprocess.Popen[str]) -> str:
    """Return the loaded command name for this extension instance.

    In a developer machine that still has another rpc-tree copy installed, Pi may
    suffix duplicate commands as rpc-tree:1/rpc-tree:2. The contract is the same;
    the smoke test should exercise this checkout's extension.
    """
    send(proc, {"id": "commands", "type": "get_commands"})
    events = run_until(proc, "commands")
    response = next(event for event in events if event.get("id") == "commands")
    commands = response.get("data", {}).get("commands", [])
    extension_path = str(EXTENSION_PATH)
    for command in commands:
        if command.get("source") == "extension" and command.get("sourceInfo", {}).get("path") == extension_path:
            return command["name"]
    for command in commands:
        if command.get("name") == "rpc-tree":
            return "rpc-tree"
    raise AssertionError(f"rpc-tree command not found in {commands!r}")


def slash(command: str, args: str = "") -> str:
    return f"/{command}{(' ' + args) if args else ''}"


def test_help() -> None:
    proc = rpc_process(["--no-session"])
    try:
        command = discover_command(proc)
        send(proc, {"id": "help", "type": "prompt", "message": slash(command, "--help")})
        events = run_until(proc, "help")
        assert any(event.get("id") == "help" and event.get("success") is True for event in events), events
        assert payloads(events) == [], payloads(events)
    finally:
        stop(proc)


def test_parse_error() -> None:
    proc = rpc_process(["--no-session"])
    try:
        command = discover_command(proc)
        send(proc, {"id": "parse", "type": "prompt", "message": slash(command, "--id")})
        payload = latest_payload(run_until_payload(proc))
        assert payload["kind"] == "error" and payload["phase"] == "parse", payload
    finally:
        stop(proc)


def test_bad_id() -> None:
    proc = rpc_process(["--no-session"])
    try:
        command = discover_command(proc)
        send(proc, {"id": "bad", "type": "prompt", "message": slash(command, "--id notfound --no-summary")})
        payload = latest_payload(run_until_payload(proc))
        assert payload["kind"] == "error" and payload["phase"] == "preflight", payload
        assert payload["targetId"] == "notfound", payload
    finally:
        stop(proc)


def test_no_picker_choices() -> None:
    proc = rpc_process(["--no-session"])
    try:
        command = discover_command(proc)
        send(proc, {"id": "fresh", "type": "prompt", "message": slash(command)})
        payload = latest_payload(run_until_payload(proc))
        assert payload["kind"] == "error" and payload["phase"] == "picker", payload
    finally:
        stop(proc)


def test_picker_cancel() -> None:
    proc = rpc_process(["--no-session"])

    def cancel_picker(obj: dict[str, Any], p: subprocess.Popen[str]) -> None:
        if obj.get("type") == "extension_ui_request" and obj.get("method") == "select" and obj.get("title") == "Pi session tree":
            send(p, {"type": "extension_ui_response", "id": obj["id"], "cancelled": True})

    try:
        command = discover_command(proc)
        send(proc, {"id": "cancel", "type": "prompt", "message": slash(command, "--all")})
        payload = latest_payload(run_until_payload(proc, on_event=cancel_picker))
        assert payload["kind"] == "cancelled" and payload["phase"] == "picker", payload
    finally:
        stop(proc)


def test_picker_noop() -> None:
    proc = rpc_process(["--no-session"])

    def choose_current(obj: dict[str, Any], p: subprocess.Popen[str]) -> None:
        if obj.get("type") == "extension_ui_request" and obj.get("method") == "select" and obj.get("title") == "Pi session tree":
            options = obj.get("options") or []
            send(p, {"type": "extension_ui_response", "id": obj["id"], "value": options[-1]})

    try:
        command = discover_command(proc)
        send(proc, {"id": "noop", "type": "prompt", "message": slash(command, "--all")})
        payload = latest_payload(run_until_payload(proc, on_event=choose_current))
        assert payload["kind"] == "noop" and payload["phase"] == "picker", payload
    finally:
        stop(proc)


def test_picker_navigated() -> None:
    proc = rpc_process(["--no-session"])

    def choose_first_no_summary(obj: dict[str, Any], p: subprocess.Popen[str]) -> None:
        if obj.get("type") != "extension_ui_request":
            return
        if obj.get("method") == "select" and obj.get("title") == "Pi session tree":
            options = obj.get("options") or []
            send(p, {"type": "extension_ui_response", "id": obj["id"], "value": options[0]})
        elif obj.get("method") == "select" and obj.get("title") == "Summarize branch?":
            send(p, {"type": "extension_ui_response", "id": obj["id"], "value": "No summary"})

    try:
        command = discover_command(proc)
        send(proc, {"id": "bash", "type": "bash", "command": "printf ok"})
        run_until(proc, "bash")
        send(proc, {"id": "nav", "type": "prompt", "message": slash(command, "--all")})
        payload = latest_payload(run_until_payload(proc, on_event=choose_first_no_summary))
        assert payload["kind"] == "navigated" and payload["phase"] == "navigation", payload
    finally:
        stop(proc)


def test_root_leaf_is_null() -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as file:
        session = file.name
        file.write(
            json.dumps(
                {
                    "type": "session",
                    "version": 3,
                    "id": "00000000-0000-0000-0000-000000000000",
                    "timestamp": "2026-01-01T00:00:00.000Z",
                    "cwd": "/tmp",
                }
            )
            + "\n"
        )
        file.write(
            json.dumps(
                {
                    "type": "message",
                    "id": "aaaaaaaa",
                    "parentId": None,
                    "timestamp": "2026-01-01T00:00:01.000Z",
                    "message": {
                        "role": "user",
                        "content": [{"type": "text", "text": "root prompt"}],
                        "timestamp": 1780000000000,
                    },
                }
            )
            + "\n"
        )

    proc = rpc_process(["--session", session])
    try:
        command = discover_command(proc)
        send(proc, {"id": "root", "type": "prompt", "message": slash(command, "--id aaaaaaaa --no-summary")})
        payload = latest_payload(run_until_payload(proc, timeout=12))
        assert payload["kind"] == "navigated" and payload.get("newLeafId") is None, payload
    finally:
        stop(proc)
        os.unlink(session)


def main() -> int:
    tests = [
        test_help,
        test_parse_error,
        test_bad_id,
        test_no_picker_choices,
        test_picker_cancel,
        test_picker_noop,
        test_picker_navigated,
        test_root_leaf_is_null,
    ]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
