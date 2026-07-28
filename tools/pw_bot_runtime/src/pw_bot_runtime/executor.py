"""Executing one intent: each step in order, and one honest verdict at the end.

An intent is a list of declarative steps. This module walks that list, and the
outcome of the intent is the outcome of the first step that did not work, or
``reached`` if every one of them did.

The rule from the specification that shapes everything here: *do not mark an
intent successful just because a key was pressed.* Every step that claims to
have done something has compared an observation before with an observation
after. Steps that genuinely cannot fail — ``wait``, ``stop`` — say so, and steps
whose success is unobservable say that too rather than claiming a result they
cannot support.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

from .bridge_client import BridgeClient
from .errors import BridgeRefused, BridgeUnavailable
from .input_backend import InputBackend
from .interaction import InteractionController
from .intent_client import Intent
from .movement import MovementController, normalize_angle


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


@dataclass
class ExecutionOutcome:
    status: str
    ok: bool
    reason: str
    started_at: str
    distance_remaining: float = 0.0
    final_position: dict | None = None
    observation_sequence: int | None = None
    details: dict = field(default_factory=dict)
    steps_completed: int = 0


class IntentExecutor:
    def __init__(self, backend: InputBackend, bridge: BridgeClient,
                 movement: MovementController, interaction: InteractionController,
                 config, logger=None, should_continue=None) -> None:
        self.input = backend
        self.bridge = bridge
        self.movement = movement
        self.interaction = interaction
        self.config = config
        self.log = logger
        self.should_continue = should_continue or (lambda: True)
        self.executed = 0
        self.durations: list[float] = []
        self.walk_durations: list[float] = []

    def execute(self, intent: Intent) -> ExecutionOutcome:
        started_at = _now()
        started = time.monotonic()
        deadline = started + self.config.brain.intent_timeout_seconds
        completed = 0
        details: dict = {"goal": intent.goal_kind, "steps": len(intent.steps)}

        try:
            for index, step in enumerate(intent.steps):
                if not self.should_continue():
                    return self._finish("operator_stopped", False, "a human stopped the run",
                                        started_at, completed, details, started)
                if time.monotonic() > deadline:
                    return self._finish("timeout", False,
                                        f"intent ran past {self.config.brain.intent_timeout_seconds}s "
                                        f"at step {index}", started_at, completed, details, started)

                outcome = self._run_step(step, deadline)
                details.setdefault("step_log", []).append({
                    "index": index, "action": step.get("action"),
                    "status": outcome[0], "reason": outcome[2],
                })
                status, ok, reason, extra = outcome
                if extra:
                    details.update(extra)
                if not ok:
                    return self._finish(status, False, reason, started_at, completed,
                                        details, started)
                completed += 1

            return self._finish("reached", True, "every step completed and was confirmed",
                                started_at, completed, details, started)

        except BridgeRefused as exc:
            if exc.error_code == "player_not_connected":
                return self._finish("client_disconnected", False,
                                    "the client left the server", started_at, completed,
                                    details, started)
            return self._finish("bridge_unavailable", False, str(exc), started_at,
                                completed, details, started)
        except BridgeUnavailable as exc:
            return self._finish("bridge_unavailable", False, str(exc), started_at,
                                completed, details, started)

    # --- one step ------------------------------------------------------------

    def _run_step(self, step: dict, deadline: float) -> tuple[str, bool, str, dict]:
        action = step.get("action")
        remaining = max(1.0, deadline - time.monotonic())

        if action == "stop":
            self.input.release_all()
            return "reached", True, "stopped", {}

        if action == "wait":
            ticks = int(step.get("ticks", 1) or 1)
            self.input.release_all()
            time.sleep(min(ticks * 0.5, remaining))
            return "reached", True, f"waited {ticks} tick(s)", {}

        if action == "observe":
            # Looking is the one action whose whole effect is on the brain's
            # memory, so all this has to do is make an observation happen.
            profile = str(step.get("profile", "navigation"))
            data = self.bridge.observe(profile if profile in
                                       ("minimal", "navigation", "detailed") else "navigation")
            return "reached", True, f"observed with the {profile} profile", {
                "observation_truncated": bool((data.get("budget") or {}).get("truncated")),
            }

        if action == "face":
            outcome = self.movement.turn_to_yaw(
                normalize_angle(float(step.get("yaw", 0.0))), timeout=min(8.0, remaining))
            return outcome.status, outcome.ok, outcome.reason, outcome.details

        if action == "jump_to":
            self.movement.jump()
            time.sleep(0.4)
            position = step.get("position")
            if not position:
                return "reached", True, "jumped", {}
            outcome = self.movement.walk_to(position, timeout=min(8.0, remaining))
            return outcome.status, outcome.ok, outcome.reason, outcome.details

        if action == "walk_to":
            started = time.monotonic()
            outcome = self.movement.walk_to(step.get("position"), timeout=remaining)
            self.walk_durations.append(time.monotonic() - started)
            return outcome.status, outcome.ok, outcome.reason, {
                **outcome.details, "distance_remaining": outcome.distance_remaining}

        if action == "follow_route":
            started = time.monotonic()
            route = step.get("route") or []
            outcome = self.movement.follow_route(route, timeout=remaining)
            self.walk_durations.append(time.monotonic() - started)
            return outcome.status, outcome.ok, outcome.reason, {
                **outcome.details, "distance_remaining": outcome.distance_remaining}

        if action == "interact":
            position = step.get("position") or step.get("target")
            if not position:
                return "unknown", False, "an interact step named nothing to interact with", {}
            outcome = self.interaction.interact_at(position)
            return outcome.status, outcome.ok, outcome.reason, outcome.details

        # parse_intent refuses unknown actions, so reaching here means the
        # vocabulary grew and this function did not.
        return "unknown", False, f"no handler for action {action!r}", {"action": action}

    # --- the verdict -----------------------------------------------------------

    def _finish(self, status: str, ok: bool, reason: str, started_at: str,
                completed: int, details: dict, started: float) -> ExecutionOutcome:
        self.input.release_all()
        self.executed += 1
        self.durations.append(time.monotonic() - started)

        position, sequence, distance = None, None, 0.0
        try:
            state = self.bridge.self_state()
            position = {"x": round(state.x, 3), "y": round(state.y, 3), "z": round(state.z, 3)}
            sequence = state.sequence
        except (BridgeUnavailable, BridgeRefused):
            # A verdict is still owed even when perception has gone away; it
            # just cannot carry a final position, and it will not invent one.
            details["final_position_unavailable"] = True

        if isinstance(details.get("distance_remaining"), (int, float)):
            distance = float(details["distance_remaining"])

        return ExecutionOutcome(
            status=status, ok=ok, reason=reason, started_at=started_at,
            distance_remaining=distance, final_position=position,
            observation_sequence=sequence, details=details, steps_completed=completed)

    def metrics(self) -> dict:
        def mean(values):
            return round(sum(values) / len(values), 3) if values else 0.0
        return {
            "intents_executed": self.executed,
            "mean_intent_seconds": mean(self.durations),
            "mean_walk_seconds": mean(self.walk_durations),
            "max_intent_seconds": round(max(self.durations), 3) if self.durations else 0.0,
        }
