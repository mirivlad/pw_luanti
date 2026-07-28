"""Claiming intents from the brain and reporting back what a body could do.

The brain writes an intent; the runtime claims it by moving the file out of the
spool; the runtime writes a result. Claiming by rename rather than by reading is
what makes the protocol safe against two runtimes and against its own crashes:
the file exists in exactly one place at a time, and a claim either happened or
did not.

An intent id is executed at most once, ever. The runtime keeps a record of what
it has finished, so a crash between claiming and reporting cannot turn into the
same walk happening twice after a restart.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from .errors import IntentInvalid

PROTOCOL = "pw_player_bot/v1"

#: Every outcome the brain understands. Mirrors ``transport.STATUSES`` in
#: pw_player_bot; sending anything else gets the result rejected, on purpose.
STATUSES = (
    "reached", "blocked", "timeout", "no_progress", "fell", "entered_liquid",
    "lost_ground", "blocked_head", "client_disconnected", "bridge_unavailable",
    "brain_cancelled", "operator_stopped", "unknown",
)

#: Actions this runtime knows how to perform. An intent containing anything else
#: is refused whole rather than partially executed — a plan half done is a bot
#: somewhere nobody predicted.
SUPPORTED_ACTIONS = ("face", "walk_to", "follow_route", "jump_to", "interact",
                     "observe", "wait", "stop")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


@dataclass
class Intent:
    """One decision from the brain, ready to be carried out."""

    intent_id: str
    goal_kind: str
    steps: list
    raw: dict
    expires_after_ticks: int = 10
    claimed_at: float = field(default_factory=time.monotonic)

    @property
    def route(self) -> list:
        plan = self.raw.get("plan") or {}
        route = plan.get("route")
        return route if isinstance(route, list) else []

    @property
    def constraints(self) -> dict:
        return self.raw.get("constraints") or {}

    @property
    def target(self):
        goal = self.raw.get("goal") or {}
        target = goal.get("target")
        return target if isinstance(target, dict) else None

    def age_seconds(self) -> float:
        return time.monotonic() - self.claimed_at


def parse_intent(document: dict) -> Intent:
    """Turn a spool document into an intent, or refuse it with a reason."""
    if not isinstance(document, dict):
        raise IntentInvalid("intent is not an object")
    if document.get("protocol") != PROTOCOL:
        raise IntentInvalid(f"wrong protocol: {document.get('protocol')!r}",
                            expected=PROTOCOL)
    intent_id = document.get("intent_id")
    if not isinstance(intent_id, str) or not intent_id:
        raise IntentInvalid("intent has no id")
    plan = document.get("plan")
    if not isinstance(plan, dict):
        raise IntentInvalid("intent has no plan", intent_id=intent_id)

    raw_steps = plan.get("steps")
    steps = raw_steps if isinstance(raw_steps, list) else []
    for step in steps:
        if not isinstance(step, dict) or "action" not in step:
            raise IntentInvalid("a step has no action", intent_id=intent_id)
        if step["action"] not in SUPPORTED_ACTIONS:
            raise IntentInvalid(f"unsupported action {step['action']!r}",
                                intent_id=intent_id, action=step["action"])

    goal = document.get("goal") or {}
    return Intent(
        intent_id=intent_id,
        goal_kind=str(goal.get("kind", "unknown")),
        steps=steps,
        raw=document,
        expires_after_ticks=int(document.get("expires_after_ticks", 10) or 10),
    )


class IntentClient:
    """The runtime's end of ``<worldpath>/pw_player_bot``."""

    def __init__(self, spool_root: Path, player_name: str, state_dir: Path | None = None,
                 logger=None) -> None:
        self.root = Path(spool_root)
        self.player_name = player_name
        self.log = logger
        self.state_dir = Path(state_dir) if state_dir else None
        self.claimed = 0
        self.reported = 0
        self.rejected = 0
        self._finished: set[str] = set()
        self._load_finished()

    # --- paths -------------------------------------------------------------

    @property
    def intents_dir(self) -> Path:
        return self.root / "intents" / self.player_name

    @property
    def results_dir(self) -> Path:
        return self.root / "results" / self.player_name

    @property
    def state_path(self) -> Path:
        return self.root / "state" / f"{self.player_name}.json"

    @property
    def _ledger_path(self) -> Path | None:
        return (self.state_dir / "executed-intents.txt") if self.state_dir else None

    def is_ready(self) -> tuple[bool, str]:
        if not self.root.exists():
            return False, (f"no brain spool at {self.root}; run "
                           f"/pw_player_bot_transport start")
        if not self.intents_dir.exists():
            return False, f"no intent directory for {self.player_name}; is the brain thinking?"
        if not os.access(self.root / "results", os.W_OK):
            return False, f"{self.root / 'results'} is not writable"
        return True, str(self.root)

    # --- crash recovery ----------------------------------------------------

    def _load_finished(self) -> None:
        path = self._ledger_path
        if path and path.exists():
            self._finished = {line.strip() for line in
                              path.read_text(encoding="utf-8").splitlines() if line.strip()}

    def _remember_finished(self, intent_id: str) -> None:
        self._finished.add(intent_id)
        path = self._ledger_path
        if not path:
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(intent_id + "\n")
            handle.flush()
            os.fsync(handle.fileno())

    def has_executed(self, intent_id: str) -> bool:
        return intent_id in self._finished

    # --- claiming ----------------------------------------------------------

    def brain_state(self) -> dict:
        if not self.state_path.exists():
            return {}
        try:
            return json.loads(self.state_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return {}

    def claim(self) -> Intent | None:
        """Take the newest intent waiting, if any.

        Newest, not oldest: an intent is a current decision, and a queue of them
        means the brain thought several times while the body was busy. The stale
        ones are not a backlog to work through, they are opinions that have been
        superseded, and they are discarded rather than walked.
        """
        if not self.intents_dir.exists():
            return None
        files = sorted(path for path in self.intents_dir.glob("*.json") if path.is_file())
        if not files:
            return None

        newest = files[-1]
        for stale in files[:-1]:
            try:
                stale.unlink()
            except OSError:
                pass

        claimed_path = newest.with_suffix(".json.claimed")
        try:
            os.replace(newest, claimed_path)
        except OSError:
            # Something else took it first. Nothing to do and nothing wrong.
            return None

        try:
            document = json.loads(claimed_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            self.rejected += 1
            claimed_path.unlink(missing_ok=True)
            raise IntentInvalid(f"claimed intent is not readable JSON: {exc}") from exc

        claimed_path.unlink(missing_ok=True)

        intent = parse_intent(document)
        if self.has_executed(intent.intent_id):
            # A restart replayed something already finished. Refusing it here is
            # what keeps "at most once" true across a crash.
            self.rejected += 1
            return None
        self.claimed += 1
        return intent

    # --- reporting ---------------------------------------------------------

    def report(self, intent: Intent, status: str, ok: bool, *,
               reason: str = "", started_at: str = "", final_position=None,
               distance_remaining: float | None = None,
               observation_sequence: int | None = None,
               details: dict | None = None) -> dict:
        """Write an execution result for the brain to ingest.

        Success is never assumed from having pressed a key. Every caller of this
        method has already compared an observation to a target; ``status`` is a
        statement about the world, not about the keyboard.
        """
        if status not in STATUSES:
            raise IntentInvalid(f"{status!r} is not an outcome the brain understands",
                                known=list(STATUSES))
        document = {
            "protocol": PROTOCOL,
            "intent_id": intent.intent_id,
            "bot": self.player_name,
            "ok": bool(ok),
            "status": status,
            "started_at": started_at or _now(),
            "finished_at": _now(),
            "reason": reason or status,
            "goal_kind": intent.goal_kind,
        }
        if final_position is not None:
            document["final_position"] = _position_dict(final_position)
        if distance_remaining is not None:
            document["distance_remaining"] = round(float(distance_remaining), 3)
        if observation_sequence is not None:
            document["observation_sequence"] = int(observation_sequence)
        if details:
            document["details"] = details

        self.results_dir.mkdir(parents=True, exist_ok=True)
        target = self.results_dir / f"{intent.intent_id}.json"
        temporary = self.results_dir / f".{intent.intent_id}.json.tmp"
        temporary.write_text(json.dumps(document), encoding="utf-8")
        os.replace(temporary, target)

        self._remember_finished(intent.intent_id)
        self.reported += 1
        return document

    def metrics(self) -> dict:
        return {
            "intents_claimed": self.claimed,
            "results_reported": self.reported,
            "intents_rejected": self.rejected,
        }


def _position_dict(value) -> dict:
    if isinstance(value, dict):
        return {"x": round(float(value.get("x", 0)), 3),
                "y": round(float(value.get("y", 0)), 3),
                "z": round(float(value.get("z", 0)), 3)}
    x, y, z = value
    return {"x": round(float(x), 3), "y": round(float(y), 3), "z": round(float(z), 3)}
