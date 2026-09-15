#!/usr/bin/env python3
"""Create and reap isolated process groups for the complete-suite test gate.

Usage:
  fm-test-lane-guard.py run <command> [args...]
  fm-test-lane-guard.py watch <parent-pid> <parent-start> <groups-file>
  fm-test-lane-guard.py reap <groups-file>

`run` creates a new session, making its process PID the process-group ID, then
executes the lane command.
The caller appends that PID to groups-file.

`watch` remains independent of the parent it observes.
If the parent's PID disappears or its process-start identity changes, the
watcher terminates every recorded process group, waits briefly, and then kills
any survivors.
This covers parent SIGKILL and other exits that cannot run shell traps.

`reap` performs the same bounded group cleanup for the normal shell EXIT trap.
Only positive numeric group IDs from the private groups-file are considered,
and the guard refuses to signal its own process group.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def fail(message: str) -> "NoReturn":
    print(f"fm-test-lane-guard: {message}", file=sys.stderr)
    raise SystemExit(2)


def process_start(pid: int) -> str:
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def read_groups(path: Path) -> list[int]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []
    own_group = os.getpgrp()
    groups: list[int] = []
    seen: set[int] = set()
    for line in lines:
        value = line.strip()
        if not value:
            continue
        if not value.isdigit() or int(value) <= 1:
            fail(f"invalid process-group id in {path}: {value!r}")
        group = int(value)
        if group == own_group:
            fail(f"refusing to signal own process group {group}")
        if group not in seen:
            groups.append(group)
            seen.add(group)
    return groups


def group_exists(group: int) -> bool:
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def signal_groups(groups: list[int], sig: signal.Signals) -> None:
    for group in groups:
        try:
            os.killpg(group, sig)
        except ProcessLookupError:
            continue


def reap(path: Path) -> None:
    groups = read_groups(path)
    signal_groups(groups, signal.SIGTERM)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if not any(group_exists(group) for group in groups):
            return
        time.sleep(0.1)
    signal_groups([group for group in groups if group_exists(group)], signal.SIGKILL)


def run(argv: list[str]) -> None:
    if not argv:
        fail("run requires a command")
    os.setsid()
    os.execvp(argv[0], argv)


def watch(argv: list[str]) -> None:
    if len(argv) != 3:
        fail("watch requires <parent-pid> <parent-start> <groups-file>")
    try:
        parent_pid = int(argv[0])
    except ValueError:
        fail(f"invalid parent pid: {argv[0]!r}")
    parent_start = argv[1]
    groups_file = Path(argv[2])
    if parent_pid <= 1 or not parent_start:
        fail("watch requires a positive parent pid and non-empty start identity")
    while process_start(parent_pid) == parent_start:
        time.sleep(0.5)
    reap(groups_file)


def main() -> None:
    if len(sys.argv) < 2:
        fail("expected run, watch, or reap")
    command = sys.argv[1]
    if command == "run":
        run(sys.argv[2:])
    if command == "watch":
        watch(sys.argv[2:])
        return
    if command == "reap":
        if len(sys.argv) != 3:
            fail("reap requires <groups-file>")
        reap(Path(sys.argv[2]))
        return
    fail(f"unknown command: {command}")


if __name__ == "__main__":
    main()
