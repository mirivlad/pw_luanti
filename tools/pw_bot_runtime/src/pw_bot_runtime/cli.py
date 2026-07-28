"""The ``pw-bot-runtime`` command line.

    pw-bot-runtime doctor [--visible]
    pw-bot-runtime run [--visible|--headless] [--keep-open] [--config F]
    pw-bot-runtime status|pause|resume|stop|screenshot --run-id ID

``doctor`` is the one to run first. It checks every dependency and every path
the runtime will need, prints the exact command to fix whatever is missing, and
exits non-zero when something required is absent — so it works as a gate in a
script as well as a thing a human reads.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from .config import Config, load_config
from .display import find_free_display
from .errors import ConfigError, RuntimeError_
from .input_backend import available_backends
from .lifecycle import BotRun, ControlState
from .process import screenshot
from .reporting import new_run_id

PROJECT_ROOT = Path(__file__).resolve().parents[4]


# --------------------------------------------------------------------------
# doctor
# --------------------------------------------------------------------------

class Check:
    def __init__(self, name: str, ok: bool, detail: str = "",
                 required: bool = True, hint: str = "") -> None:
        self.name, self.ok, self.detail = name, ok, detail
        self.required, self.hint = required, hint

    def line(self) -> str:
        mark = "ok  " if self.ok else ("FAIL" if self.required else "warn")
        text = f"  [{mark}] {self.name:<26} {self.detail}"
        if not self.ok and self.hint:
            text += f"\n         fix: {self.hint}"
        return text

    def as_dict(self) -> dict:
        return {"name": self.name, "ok": self.ok, "detail": self.detail,
                "required": self.required, "hint": self.hint}


def _binary(name: str, package: str, required: bool = True, purpose: str = "") -> Check:
    path = shutil.which(name)
    return Check(name, path is not None, path or f"not found{purpose and ' — ' + purpose}",
                 required, f"sudo apt-get install -y {package}")


def run_doctor(config: Config, visible: bool) -> tuple[list[Check], bool]:
    checks: list[Check] = []

    checks.append(Check("python", sys.version_info >= (3, 11),
                        f"{sys.version.split()[0]}", True,
                        "install Python 3.11 or newer (tomllib is required)"))
    checks.append(_binary(config.client.binary, "luanti", True, "the real client the bot drives"))
    checks.append(_binary("Xvfb", "xvfb", True, "headless display"))
    checks.append(_binary("Xephyr", "xserver-xephyr", visible,
                          "visible mode's nested X server"))
    checks.append(_binary("ffplay", "ffmpeg", False, "fallback visible mirror"))
    checks.append(_binary("xdotool", "xdotool", True, "window identification and fallback input"))

    backends = available_backends()
    checks.append(Check("input backend: xtest", backends["xtest"],
                        "python-xlib present" if backends["xtest"] else "python-xlib missing",
                        False, "sudo apt-get install -y python3-xlib"))
    checks.append(Check("input backend: xdotool", backends["xdotool"],
                        "present" if backends["xdotool"] else "missing", False,
                        "sudo apt-get install -y xdotool"))
    checks.append(Check("any input backend", any(backends.values()),
                        ", ".join(name for name, ok in backends.items() if ok) or "none",
                        True, "sudo apt-get install -y python3-xlib xdotool"))

    has_shot = shutil.which("import") or shutil.which("scrot")
    checks.append(Check("screenshot tool", bool(has_shot),
                        has_shot or "neither import nor scrot", False,
                        "sudo apt-get install -y imagemagick"))

    if visible:
        parent = os.environ.get("DISPLAY", "")
        checks.append(Check("parent DISPLAY", bool(parent), parent or "not set", True,
                            "run visible mode from a desktop session"))

    try:
        free = find_free_display(config.display.display_search_start,
                                 config.display.display_search_end)
        checks.append(Check("free X display", True, f":{free}"))
    except RuntimeError_ as exc:
        checks.append(Check("free X display", False, str(exc), True,
                            "close stale Xvfb processes, or widen display.display_search_*"))

    ok, detail = config.check_password_file()
    checks.append(Check("password file", ok, detail, True,
                        f"chmod 600 {config.password_path}"))

    world = config.world_path
    checks.append(Check("world path", world.exists(), str(world), True,
                        "set server.world_path to the server's world directory"))

    bridge_spool = config.bridge_spool
    bridge_requests = bridge_spool / "requests" / config.server.player_name
    checks.append(Check(
        "bridge transport", bridge_requests.exists(),
        str(bridge_requests) if bridge_requests.exists() else f"missing {bridge_requests}",
        True,
        "in game: /pw_bot_bridge_register <bot> player && /pw_bot_bridge_transport start"))

    brain_intents = config.brain_spool / "intents" / config.server.player_name
    checks.append(Check(
        "brain transport", brain_intents.exists(),
        str(brain_intents) if brain_intents.exists() else f"missing {brain_intents}",
        True,
        "in game: /pw_player_bot_start <bot> && /pw_player_bot_transport start"))

    artifacts = config.artifacts_path
    try:
        artifacts.mkdir(parents=True, exist_ok=True)
        writable = os.access(artifacts, os.W_OK)
    except OSError as exc:
        writable, artifacts = False, exc
    checks.append(Check("artifacts directory", bool(writable), str(artifacts), True,
                        f"mkdir -p {config.artifacts_path}"))

    required_ok = all(check.ok for check in checks if check.required)
    return checks, required_ok


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def _load(args) -> Config:
    overrides = {}
    if args.player_name:
        overrides["server.player_name"] = args.player_name
    if args.password_file:
        overrides["server.password_file"] = args.password_file
    if args.server_address:
        overrides["server.address"] = args.server_address
    if args.server_port:
        overrides["server.port"] = args.server_port
    if getattr(args, "visible", False):
        overrides["display.mode"] = "visible"
    if getattr(args, "headless", False):
        overrides["display.mode"] = "headless"
    if getattr(args, "keep_open", False):
        overrides["client.keep_open_after_run"] = True
    if getattr(args, "close_after_run", False):
        overrides["client.keep_open_after_run"] = False
    return load_config(args.config, PROJECT_ROOT, overrides)


def cmd_doctor(args) -> int:
    config = _load(args)
    checks, ok = run_doctor(config, args.visible)
    if args.json:
        print(json.dumps({"ok": ok, "checks": [check.as_dict() for check in checks]}, indent=2))
        return 0 if ok else 1
    print(f"pw-bot-runtime doctor ({'visible' if args.visible else 'headless'} mode)")
    for check in checks:
        print(check.line())
    print()
    if ok:
        print("Everything required is present.")
        return 0
    print("Something required is missing; the fixes are above.")
    return 1


def cmd_run(args) -> int:
    config = _load(args)
    checks, ok = run_doctor(config, config.display.mode == "visible")
    if not ok:
        print("refusing to start: the environment is not ready", file=sys.stderr)
        for check in checks:
            if check.required and not check.ok:
                print(check.line(), file=sys.stderr)
        return 2

    run = BotRun(config, run_id=args.run_id or new_run_id(),
                 max_intents=args.max_intents, max_seconds=args.max_seconds)
    print(f"run id: {run.run_id}")
    print(f"artifacts: {run.artifacts.directory}")
    result = run.run()
    print()
    print(f"verdict: {'ok' if result['ok'] else 'FAILED'} ({result['status']}) — {result['reason']}")
    print(f"summary: {run.artifacts.directory / 'summary.md'}")
    return 0 if result["ok"] else 1


def _run_directory(config: Config, run_id: str) -> Path:
    directory = config.artifacts_path / run_id
    if not directory.exists():
        raise ConfigError(f"no such run: {directory}")
    return directory


def cmd_control(args, command: str) -> int:
    config = _load(args)
    directory = _run_directory(config, args.run_id)
    ControlState(directory).send(command)
    print(f"{command} requested for {args.run_id}")
    return 0


def cmd_status(args) -> int:
    config = _load(args)
    directory = _run_directory(config, args.run_id)
    result_path = directory / "result.json"
    if result_path.exists():
        document = json.loads(result_path.read_text(encoding="utf-8"))
        print(json.dumps({
            "run_id": document.get("run_id"), "ok": document.get("ok"),
            "status": document.get("status"), "reason": document.get("reason"),
            "duration_seconds": document.get("duration_seconds"),
            "metrics": document.get("metrics", {}),
        }, indent=2))
        return 0
    # Still running: the newest lines of the log are the live status.
    log = directory / "runtime.log"
    if log.exists():
        lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
        print(f"run {args.run_id} is in progress")
        for line in lines[-12:]:
            print("  " + line)
        return 0
    print(f"run {args.run_id} has produced nothing yet")
    return 1


def cmd_screenshot(args) -> int:
    config = _load(args)
    directory = _run_directory(config, args.run_id)
    display_file = directory / "display.json"
    if not display_file.exists():
        print("this run has no display record yet", file=sys.stderr)
        return 1
    display = json.loads(display_file.read_text(encoding="utf-8")).get("display")
    if not display:
        print("this run's display is unknown", file=sys.stderr)
        return 1
    target = directory / "screenshots" / f"operator-{new_run_id('shot')}.png"
    if screenshot(display, target):
        print(target)
        return 0
    print("could not capture the display", file=sys.stderr)
    return 1


# --------------------------------------------------------------------------
# parser
# --------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pw-bot-runtime",
        description="Drive a real Luanti client from pw_player_bot intents.")

    # Shared options live on every subcommand rather than before it, so
    # `run --config F` works — which is how anyone would naturally type it.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--config", default=None, help="path to a TOML config file")
    common.add_argument("--player-name", default=None)
    common.add_argument("--password-file", default=None)
    common.add_argument("--server-address", default=None)
    common.add_argument("--server-port", type=int, default=None)

    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor = subparsers.add_parser("doctor", parents=[common], help="check the environment")
    doctor.add_argument("--visible", action="store_true",
                        help="also require what visible mode needs")
    doctor.add_argument("--json", action="store_true")
    doctor.set_defaults(func=cmd_doctor)

    run = subparsers.add_parser("run", parents=[common], help="run the bot")
    mode = run.add_mutually_exclusive_group()
    mode.add_argument("--visible", action="store_true",
                      help="show the real client in a window an operator can watch")
    mode.add_argument("--headless", action="store_true",
                      help="run on an isolated virtual display (the default)")
    keep = run.add_mutually_exclusive_group()
    keep.add_argument("--keep-open", action="store_true",
                      help="leave the client running when the run ends")
    keep.add_argument("--close-after-run", action="store_true")
    run.add_argument("--run-id", default=None)
    run.add_argument("--max-intents", type=int, default=0,
                     help="stop after this many intents (0 means no limit)")
    run.add_argument("--max-seconds", type=float, default=0.0,
                     help="stop after this long (0 means no limit)")
    run.set_defaults(func=cmd_run)

    for name, handler in (("pause", lambda a: cmd_control(a, "pause")),
                          ("resume", lambda a: cmd_control(a, "resume")),
                          ("stop", lambda a: cmd_control(a, "stop"))):
        sub = subparsers.add_parser(name, parents=[common], help=f"{name} a running bot")
        sub.add_argument("--run-id", required=True)
        sub.set_defaults(func=handler)

    status = subparsers.add_parser("status", parents=[common],
                                   help="what a run is doing or did")
    status.add_argument("--run-id", required=True)
    status.set_defaults(func=cmd_status)

    shot = subparsers.add_parser("screenshot", parents=[common],
                                 help="capture a run's display for a human")
    shot.add_argument("--run-id", required=True)
    shot.set_defaults(func=cmd_screenshot)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    for attribute in ("visible", "headless", "keep_open", "close_after_run", "run_id"):
        if not hasattr(args, attribute):
            setattr(args, attribute, False if attribute != "run_id" else None)
    try:
        return args.func(args)
    except ConfigError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2
    except RuntimeError_ as exc:
        print(f"{exc.code}: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:  # pragma: no cover
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
