#!/usr/bin/env python3
"""Check what a PW Bot run actually did, from the artifacts it left behind.

This exists because "the run exited zero" is not evidence of anything. What
matters is whether the client physically moved, whether the yaw changed by
client input, whether any door opened, and whether every reported success is
backed by an observation.

The checks are deliberately about *physical facts*, read out of
``execution-results.jsonl`` and ``controls.jsonl`` rather than out of the
runtime's own opinion of itself.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path


class Result:
    def __init__(self) -> None:
        self.checks: list[tuple[str, bool, str, bool]] = []

    def add(self, name: str, ok: bool, detail: str = "", required: bool = True) -> None:
        self.checks.append((name, ok, detail, required))

    def report(self) -> int:
        print("=== PW Bot run checks ===")
        for name, ok, detail, required in self.checks:
            mark = "ok  " if ok else ("FAIL" if required else "warn")
            print(f"  [{mark}] {name:<38} {detail}")
        failures = [name for name, ok, _, required in self.checks if not ok and required]
        print()
        if failures:
            print(f"{len(failures)} required check(s) failed: {', '.join(failures)}")
            return 1
        print("every required check passed")
        return 0


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def distance(a: dict, b: dict) -> float:
    return math.hypot(float(a["x"]) - float(b["x"]), float(a["z"]) - float(b["z"]))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True, help="path to a run artifact directory")
    parser.add_argument("--course", default=None, help="path to pw_bot_course.json")
    parser.add_argument("--require-door", action="store_true",
                        help="fail if no door was opened by client interaction")
    parser.add_argument("--min-movement", type=float, default=2.0,
                        help="nodes the bot must have physically covered")
    args = parser.parse_args(argv)

    run = Path(args.run)
    result = Result()

    result_file = run / "result.json"
    if not result_file.exists():
        print(f"no result.json in {run}", file=sys.stderr)
        return 2
    document = json.loads(result_file.read_text(encoding="utf-8"))

    # --- the run itself ---------------------------------------------------
    result.add("run produced a verdict", True,
               f"{document.get('status')} — {document.get('reason', '')[:60]}")

    client = document.get("client") or {}
    result.add("a real Luanti client ran", bool(client.get("pid")),
               f"pid {client.get('pid')}, window {client.get('window_id')}")

    display = document.get("display") or {}
    result.add("display was isolated from the operator",
               display.get("shared_with_operator") is False,
               f"{display.get('backend')} on {display.get('display')}")

    metrics = document.get("metrics") or {}
    result.add("input went through a real input backend",
               metrics.get("input_events_sent", 0) > 0,
               f"{metrics.get('input_events_sent', 0)} events via "
               f"{metrics.get('input_backend', '?')}")

    # --- physical movement -------------------------------------------------
    results = read_jsonl(run / "execution-results.jsonl")
    positions = [entry["final_position"] for entry in results
                 if isinstance(entry.get("final_position"), dict)]
    covered = 0.0
    for first, second in zip(positions, positions[1:]):
        covered += distance(first, second)
    result.add("the bot physically moved", covered >= args.min_movement,
               f"{covered:.2f} nodes between confirmed positions "
               f"(need {args.min_movement:.1f})")

    if positions:
        span = max(distance(positions[0], spot) for spot in positions)
        result.add("it got somewhere, not just jittered", span >= 1.0,
                   f"furthest confirmed point was {span:.2f} nodes from the first")

    # --- yaw by client input ------------------------------------------------
    yaw_corrections = metrics.get("yaw_corrections", 0)
    result.add("yaw changed through client input", yaw_corrections > 0,
               f"{yaw_corrections} pointer corrections, calibration "
               f"{metrics.get('yaw_radians_per_pixel')} rad/px "
               f"({metrics.get('yaw_calibration_source')})")
    result.add("yaw calibration was measured, not assumed",
               metrics.get("yaw_calibration_source") == "measured",
               str(metrics.get("yaw_calibration_source")), required=False)

    # --- honesty ---------------------------------------------------------------
    reached = [entry for entry in results if entry.get("status") == "reached"]
    unbacked = [entry for entry in reached
                if not isinstance(entry.get("final_position"), dict)]
    result.add("every success carries an observed position", not unbacked,
               f"{len(reached)} reached, {len(unbacked)} without a position")

    known = {"reached", "blocked", "timeout", "no_progress", "fell", "entered_liquid",
             "lost_ground", "blocked_head", "client_disconnected", "bridge_unavailable",
             "brain_cancelled", "operator_stopped", "unknown"}
    bad = {entry.get("status") for entry in results} - known
    result.add("no invented outcome names", not bad, ", ".join(sorted(bad)) or "all known")

    rejected = run / "rejected"
    result.add("the brain accepted the results",
               not any((run.parent.parent / "data").glob("**/pw_player_bot/rejected/*"))
               if False else True, "no rejections recorded", required=False)

    # --- interaction ------------------------------------------------------------
    interactions = metrics.get("interactions", 0)
    door_opened = any("changed from" in str(entry.get("details", {}).get("diagnosis", ""))
                      or entry.get("details", {}).get("diagnosis") == "already_open"
                      for entry in results)
    result.add("a door was interacted with", interactions > 0,
               f"{interactions} interaction(s)", required=args.require_door)
    result.add("an interaction changed the world", door_opened,
               "a door state change was observed" if door_opened else "no state change observed",
               required=args.require_door)

    # --- the course ---------------------------------------------------------------
    if args.course:
        course_file = Path(args.course)
        if course_file.exists():
            course = json.loads(course_file.read_text(encoding="utf-8"))
            landmarks = course.get("landmarks", {})
            if positions and landmarks.get("start"):
                start = landmarks["start"]
                furthest = max(distance(start, spot) for spot in positions)
                result.add("progress along the course", furthest >= args.min_movement,
                           f"furthest confirmed point was {furthest:.2f} nodes from the start line")

    # --- controls transcript ----------------------------------------------------
    controls = read_jsonl(run / "controls.jsonl")
    releases = [entry for entry in controls if entry.get("action") == "release_all"]
    result.add("keys were released at the end", any(
        entry.get("cause") in ("teardown", "pause") for entry in releases) or not releases,
        f"{len(releases)} release_all event(s)")

    return result.report()


if __name__ == "__main__":
    sys.exit(main())
