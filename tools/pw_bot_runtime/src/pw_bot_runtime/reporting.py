"""Artifacts: everything a run leaves behind for a human to read.

One directory per run, named by run id:

    runtime/pw-bot-artifacts/<run-id>/
      result.json               machine-readable verdict and metrics
      summary.md                the same thing for a person
      runtime.log               what the runtime did
      client.log                what Luanti said
      bridge-observations.jsonl one line per observation used
      intents.jsonl             one line per intent claimed
      execution-results.jsonl   one line per result reported
      controls.jsonl            one line per key or pointer event
      display.json              which display, which backend, which window
      screenshots/              images, for people only

``controls.jsonl`` is the one worth explaining. It is a complete record of every
physical action the bot took, which makes the central claim of this project
auditable rather than merely asserted: if the bot moved, there is a key event
here that moved it, and if there is no such event, it did not move by itself.

Everything written here goes through the redactor first.
"""

from __future__ import annotations

import json
import logging
import shutil
from datetime import datetime, timezone
from pathlib import Path

from .config import Config, redact


def new_run_id(prefix: str = "run") -> str:
    return f"{prefix}-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"


class RunArtifacts:
    """The directory for one run, and the streams that write into it."""

    STREAMS = ("bridge-observations", "intents", "execution-results", "controls")

    def __init__(self, root: Path, run_id: str) -> None:
        self.run_id = run_id
        self.directory = Path(root) / run_id
        self.directory.mkdir(parents=True, exist_ok=True)
        (self.directory / "screenshots").mkdir(exist_ok=True)
        self._handles: dict[str, object] = {}
        self.logger = self._make_logger()
        self.screenshot_count = 0

    # --- logging ------------------------------------------------------------

    def _make_logger(self) -> logging.Logger:
        logger = logging.getLogger(f"pw_bot_runtime.{self.run_id}")
        logger.setLevel(logging.DEBUG)
        logger.handlers.clear()
        logger.propagate = False

        file_handler = logging.FileHandler(self.directory / "runtime.log", encoding="utf-8")
        file_handler.setFormatter(logging.Formatter(
            "%(asctime)s %(levelname)-7s %(message)s", "%H:%M:%S"))
        logger.addHandler(file_handler)

        console = logging.StreamHandler()
        console.setFormatter(logging.Formatter("[pw-bot %(asctime)s] %(message)s", "%H:%M:%S"))
        console.setLevel(logging.INFO)
        logger.addHandler(console)
        return logger

    @property
    def client_log(self) -> Path:
        return self.directory / "client.log"

    # --- streams --------------------------------------------------------------

    def append(self, stream: str, record: dict) -> None:
        if stream not in self.STREAMS:
            raise ValueError(f"unknown artifact stream {stream!r}")
        handle = self._handles.get(stream)
        if handle is None:
            handle = (self.directory / f"{stream}.jsonl").open("a", encoding="utf-8")
            self._handles[stream] = handle
        payload = dict(redact(record))
        payload.setdefault("at", datetime.now(timezone.utc).isoformat(timespec="milliseconds"))
        handle.write(json.dumps(payload, sort_keys=True) + "\n")
        handle.flush()

    def write_json(self, name: str, document: dict) -> Path:
        path = self.directory / name
        path.write_text(json.dumps(redact(document), indent=2, sort_keys=True) + "\n",
                        encoding="utf-8")
        return path

    def screenshot_path(self, label: str) -> Path:
        self.screenshot_count += 1
        safe = "".join(char if char.isalnum() or char in "-_" else "-" for char in label)
        return self.directory / "screenshots" / f"{self.screenshot_count:03d}-{safe}.png"

    def close(self) -> None:
        for handle in self._handles.values():
            try:
                handle.close()
            except Exception:  # noqa: BLE001
                pass
        self._handles.clear()
        for handler in list(self.logger.handlers):
            handler.close()
            self.logger.removeHandler(handler)

    # --- the summary ------------------------------------------------------------

    def write_summary(self, result: dict) -> Path:
        lines = [
            f"# PW Bot run {self.run_id}",
            "",
            f"* **Verdict:** {'ok' if result.get('ok') else 'failed'} "
            f"({result.get('status', 'unknown')})",
            f"* **Reason:** {result.get('reason', '')}",
            f"* **Mode:** {result.get('display', {}).get('backend', '?')} "
            f"on {result.get('display', {}).get('display', '?')}",
            f"* **Player:** {result.get('player_name', '?')}",
            f"* **Duration:** {result.get('duration_seconds', 0):.1f}s",
            "",
            "## What happened",
            "",
        ]
        for entry in result.get("timeline", []):
            lines.append(f"* `{entry.get('at', '')}` {entry.get('event', '')}")

        intents = result.get("intents", [])
        if intents:
            lines += ["", "## Intents executed", "",
                      "| # | goal | status | reason | distance left |",
                      "|---|------|--------|--------|---------------|"]
            for index, entry in enumerate(intents, start=1):
                lines.append(
                    f"| {index} | {entry.get('goal', '')} | {entry.get('status', '')} | "
                    f"{entry.get('reason', '')} | {entry.get('distance_remaining', '')} |")

        metrics = result.get("metrics", {})
        if metrics:
            lines += ["", "## Metrics", "", "| metric | value |", "|--------|-------|"]
            for key in sorted(metrics):
                lines.append(f"| {key} | {metrics[key]} |")

        shots = sorted((self.directory / "screenshots").glob("*.png"))
        if shots:
            lines += ["", "## Screenshots", "",
                      "Diagnostic artifacts for a human. The runtime never reads them.", ""]
            lines += [f"* `screenshots/{shot.name}`" for shot in shots]

        path = self.directory / "summary.md"
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path


def prune_old_runs(root: Path, keep: int) -> int:
    """Keep the newest *keep* run directories and delete the rest."""
    root = Path(root)
    if not root.exists():
        return 0
    runs = sorted((path for path in root.iterdir() if path.is_dir()),
                  key=lambda path: path.name)
    removed = 0
    for path in runs[:-keep] if keep < len(runs) else []:
        shutil.rmtree(path, ignore_errors=True)
        removed += 1
    return removed


def build_result(config: Config, run_id: str, **fields) -> dict:
    """Assemble the machine-readable verdict for one run."""
    document = {
        "protocol": "pw_bot_runtime/v1",
        "run_id": run_id,
        "player_name": config.server.player_name,
        "config": config.as_redacted_dict(),
    }
    document.update(fields)
    return redact(document)
