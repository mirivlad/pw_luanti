"""Right-clicking things, and telling apart the several ways that can fail.

Opening a door is the first thing the bot does that changes the world, and it is
worth being precise about who does what:

* the brain decides that a door is worth approaching;
* the runtime walks the body there, aims at it, and right-clicks;
* the *game* opens the door, because a player clicked it;
* the bridge observes that the door is now open.

Nothing here calls ``mcl_doors.toggle_door`` or writes a node. If the click does
not open the door, the door does not open, and that is the finding — a runtime
that "helped" by setting the node would destroy the only interesting thing the
test could have told us.

Failure diagnosis matters as much as success. "The door did not open" covers a
target that was never visible, one out of reach, one that was already open, and
one that opened onto a wall, and those lead somewhere different every time.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

from .bridge_client import BridgeClient
from .errors import BridgeRefused, BridgeUnavailable
from .input_backend import InputBackend
from .movement import MovementController

#: How far a player can reach. Luanti's default hand range is 4 nodes; the
#: runtime stays inside it rather than discovering the limit by failing.
REACH_NODES = 4.0


@dataclass
class InteractionOutcome:
    status: str
    ok: bool
    reason: str = ""
    details: dict = field(default_factory=dict)


class InteractionController:
    def __init__(self, backend: InputBackend, bridge: BridgeClient,
                 movement: MovementController, logger=None) -> None:
        self.input = backend
        self.bridge = bridge
        self.movement = movement
        self.log = logger
        self.interactions = 0

    # --- looking at the thing ------------------------------------------------

    def _target_under_crosshair(self) -> dict:
        try:
            return self.bridge.inspect_target() or {}
        except (BridgeUnavailable, BridgeRefused):
            return {}

    def _door_state_at(self, position) -> dict | None:
        """What the bridge says about a door at a position, if it can see one.

        Uses only player-mode perception. The runtime never asks the oracle: it
        is standing in for a player, and a player cannot see through a door to
        check whether it worked.
        """
        try:
            observation = self.bridge.observe("detailed")
        except (BridgeUnavailable, BridgeRefused):
            return None
        wanted = (round(float(position["x"])), round(float(position["y"])),
                  round(float(position["z"])))
        for feature in observation.get("visible_features") or []:
            spot = feature.get("position") or {}
            if not spot:
                continue
            here = (round(float(spot.get("x", 0))), round(float(spot.get("y", 0))),
                    round(float(spot.get("z", 0))))
            if here == wanted:
                return feature
        return None

    # --- the interaction ------------------------------------------------------

    def interact_at(self, position, expect: str = "state_change") -> InteractionOutcome:
        """Aim at a position and right-click it, then check whether anything changed."""
        try:
            state = self.bridge.self_state()
        except (BridgeUnavailable, BridgeRefused) as exc:
            return InteractionOutcome("bridge_unavailable", False, str(exc))

        target = {"x": float(position["x"]), "y": float(position["y"]), "z": float(position["z"])}
        distance = ((target["x"] - state.x) ** 2 + (target["y"] - state.y) ** 2
                    + (target["z"] - state.z) ** 2) ** 0.5
        if distance > REACH_NODES:
            return InteractionOutcome(
                "blocked", False, "the target is out of reach",
                {"distance": round(distance, 2), "reach": REACH_NODES,
                 "diagnosis": "target_out_of_reach"})

        aim = self.movement.face_position(target)
        if not aim.ok:
            return InteractionOutcome(
                aim.status, False, "could not aim at the target",
                {"diagnosis": "could_not_aim", "aim_status": aim.status})

        # Pitch matters for a door: its lower half sits below eye level, and a
        # body looking dead ahead points at the wall above it.
        self._aim_pitch_at(target)

        before_feature = self._door_state_at(target)
        before_target = self._target_under_crosshair()
        pointed_at = (before_target.get("target") or {}).get("node") or {}
        if not pointed_at and not before_feature:
            return InteractionOutcome(
                "blocked", False, "nothing is under the crosshair",
                {"diagnosis": "target_not_visible"})

        self.input.right_click()
        self.interactions += 1
        time.sleep(0.5)

        after_feature = self._door_state_at(target)
        details = {
            "before": _summarise(before_feature),
            "after": _summarise(after_feature),
            "distance": round(distance, 2),
        }

        if after_feature is None and before_feature is not None:
            return InteractionOutcome(
                "unknown", False, "the target is no longer visible after the click",
                {**details, "diagnosis": "target_disappeared"})

        if expect == "state_change":
            changed, note = _state_changed(before_feature, after_feature)
            if changed:
                return InteractionOutcome("reached", True, note, {**details, "diagnosis": note})
            if _looks_open(before_feature):
                return InteractionOutcome(
                    "reached", True, "the door was already open",
                    {**details, "diagnosis": "already_open"})
            return InteractionOutcome(
                "blocked", False, "the click changed nothing",
                {**details, "diagnosis": "interaction_had_no_effect"})

        return InteractionOutcome("reached", True, "clicked", details)

    def _aim_pitch_at(self, target) -> None:
        """Point the head at the target's height as well as its bearing."""
        try:
            state = self.bridge.self_state()
        except (BridgeUnavailable, BridgeRefused):
            return
        horizontal = ((target["x"] - state.x) ** 2 + (target["z"] - state.z) ** 2) ** 0.5
        if horizontal < 1e-6:
            return
        import math
        # Eye height above the reported feet position.
        wanted = math.atan2(target["y"] - (state.y + 1.5), horizontal)
        error = wanted - state.pitch
        if abs(error) < math.radians(4):
            return
        radians_per_pixel = self.movement.calibration["radians_per_pixel"]
        # Pointer +y looks down, and pitch grows upward.
        pixels = int(round(-error / radians_per_pixel * self.movement.config.yaw_gain))
        self.input.move_pointer(0, max(-400, min(400, pixels)))
        time.sleep(0.25)

    def metrics(self) -> dict:
        return {"interactions": self.interactions}


def _summarise(feature) -> dict:
    if not isinstance(feature, dict):
        return {}
    return {
        "feature": feature.get("feature"),
        "node_name": feature.get("node_name"),
        "state": feature.get("state"),
        "open": feature.get("open"),
    }


def _looks_open(feature) -> bool:
    if not isinstance(feature, dict):
        return False
    if feature.get("open") is True:
        return True
    return str(feature.get("state", "")).lower() == "open"


def _state_changed(before, after) -> tuple[bool, str]:
    """Did the world actually change? Compares what perception can see.

    Deliberately conservative: it reports a change only when a field it
    understands genuinely differs. An unrecognised difference is not a success,
    because "something is different" is not "the door opened".
    """
    if not isinstance(before, dict) or not isinstance(after, dict):
        return False, "no_comparable_state"
    for field_name in ("open", "state", "node_name"):
        first, second = before.get(field_name), after.get(field_name)
        if first != second:
            return True, f"{field_name} changed from {first!r} to {second!r}"
    return False, "no_change_observed"
