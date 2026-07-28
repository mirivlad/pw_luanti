"""Walking and turning, in a closed loop against what the bridge reports.

The rule this module exists to enforce: **a key press is not an action.** The
naive implementation of "walk to that cell" is to compute a duration, hold W for
that long, and declare victory. It produces a bot that is confidently wrong —
it reports arrival while standing against a fence, and every layer above it
inherits the lie.

So every motion here is a loop:

    read position from the bridge
    -> compute the bearing to the target
    -> turn the head towards it with pointer input
    -> hold the movement key
    -> read position again
    -> did the distance actually fall?
    -> stop at the target and confirm by observation

The loop ends in exactly one of the named outcomes, and the outcome is derived
from observations. "I do not know why it stopped" is a legitimate answer and is
spelled ``unknown``; inventing a specific reason would be worse.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass, field

from .bridge_client import BridgeClient, SelfState
from .errors import BridgeRefused, BridgeUnavailable
from .input_backend import InputBackend

TAU = 2 * math.pi


def normalize_angle(radians: float) -> float:
    """Fold an angle into [0, 2pi).

    Every yaw comparison in this module goes through here. Angles that are not
    normalised produce a bot that spins 350 degrees to make a 10 degree turn,
    which looks exactly like a bug in the brain and is not.
    """
    return radians % TAU


def angle_difference(current: float, target: float) -> float:
    """Signed shortest rotation from *current* to *target*, in (-pi, pi].

    The sign is what stops the infinite spin: turning -10 degrees and turning
    +350 degrees end in the same place, and only one of them is what a body
    would do.
    """
    difference = (target - current) % TAU
    if difference > math.pi:
        difference -= TAU
    return difference


def yaw_towards(from_x: float, from_z: float, to_x: float, to_z: float) -> float:
    """Luanti's yaw convention: 0 looks along +Z and grows anticlockwise."""
    dx, dz = to_x - from_x, to_z - from_z
    if abs(dx) < 1e-9 and abs(dz) < 1e-9:
        return 0.0
    return normalize_angle(math.atan2(-dx, dz))


@dataclass
class MoveOutcome:
    """Why a motion stopped, and what the world looked like when it did."""

    status: str
    ok: bool
    reason: str = ""
    distance_remaining: float = 0.0
    final_state: SelfState | None = None
    details: dict = field(default_factory=dict)
    elapsed: float = 0.0
    corrections: int = 0


class MovementController:
    """Turns targets into key presses and observations into verdicts."""

    def __init__(self, backend: InputBackend, bridge: BridgeClient, movement_config,
                 logger=None, should_continue=None) -> None:
        self.input = backend
        self.bridge = bridge
        self.config = movement_config
        self.log = logger
        #: Called between control ticks. Returning False stops the motion with
        #: ``operator_stopped`` — this is how pause and stop reach the legs.
        self.should_continue = should_continue or (lambda: True)
        self.yaw_corrections = 0
        self.control_ticks = 0
        self.calibration: dict = {
            "radians_per_pixel": float(movement_config.yaw_radians_per_pixel),
            "source": "configured",
            "samples": [],
        }

    # --- helpers ------------------------------------------------------------

    def _tick(self) -> float:
        return self.config.control_tick_ms / 1000.0

    def _state(self) -> SelfState:
        return self.bridge.self_state()

    def _stop_moving(self) -> None:
        for key in ("forward", "backward", "left", "right"):
            if key in self.input.held_keys:
                self.input.key_up(key)

    # --- turning ------------------------------------------------------------

    def calibrate_yaw(self) -> dict:
        """Measure how much yaw one pixel of pointer motion is worth.

        Sensitivity depends on the client's own settings, so it is measured
        rather than assumed, and it is measured against the bridge rather than
        against anything the client reports about itself. Two probes in opposite
        directions, so a calibration cannot be poisoned by the bot happening to
        drift while it measures.
        """
        samples = []
        for pixels in (160, -160):
            try:
                before = self._state()
                self.input.move_pointer(pixels, 0)
                time.sleep(0.35)
                after = self._state()
            except (BridgeUnavailable, BridgeRefused):
                break
            delta = abs(angle_difference(before.yaw, after.yaw))
            if delta > 1e-4:
                samples.append(delta / abs(pixels))

        if samples:
            measured = sum(samples) / len(samples)
            # Sanity bound. A wild measurement means something moved the view
            # that was not us, and a bad calibration is worse than a default.
            if 1e-5 < measured < 0.2:
                self.calibration = {
                    "radians_per_pixel": measured,
                    "source": "measured",
                    "samples": [round(value, 6) for value in samples],
                }
        return self.calibration

    def turn_to_yaw(self, target_yaw: float, timeout: float = 6.0) -> MoveOutcome:
        """Turn the head to a bearing using pointer input only.

        Never calls a server-side look function; the only thing that moves this
        head is a pointer event, exactly as for a human.
        """
        started = time.monotonic()
        tolerance = math.radians(self.config.yaw_tolerance_degrees)
        target_yaw = normalize_angle(target_yaw)
        last_error = None
        stalled = 0

        while time.monotonic() - started < timeout:
            if not self.should_continue():
                return MoveOutcome("operator_stopped", False, "stopped while turning")
            state = self._state()
            error = angle_difference(state.yaw, target_yaw)
            if abs(error) <= tolerance:
                return MoveOutcome("reached", True, "facing the target", 0.0, state,
                                   {"yaw_error_degrees": round(math.degrees(error), 2)},
                                   time.monotonic() - started, self.yaw_corrections)

            # Yaw grows anticlockwise and the pointer's +x turns the view
            # clockwise, hence the negation.
            radians_per_pixel = self.calibration["radians_per_pixel"]
            pixels = int(round(-error / radians_per_pixel * self.config.yaw_gain))
            pixels = max(-600, min(600, pixels))
            if pixels == 0:
                pixels = 1 if error < 0 else -1

            self.input.move_pointer(pixels, 0)
            self.yaw_corrections += 1
            time.sleep(self._tick())

            if last_error is not None and abs(abs(error) - abs(last_error)) < 1e-3:
                stalled += 1
                if stalled >= 8:
                    return MoveOutcome(
                        "blocked", False, "the view will not turn",
                        0.0, state,
                        {"yaw_error_degrees": round(math.degrees(error), 2)},
                        time.monotonic() - started, self.yaw_corrections)
            else:
                stalled = 0
            last_error = error

        state = self._state()
        return MoveOutcome("timeout", False, "could not face the target in time", 0.0, state,
                           {"yaw_error_degrees": round(
                               math.degrees(angle_difference(state.yaw, target_yaw)), 2)},
                           time.monotonic() - started, self.yaw_corrections)

    def face_position(self, target) -> MoveOutcome:
        state = self._state()
        tx = float(target["x"]) if isinstance(target, dict) else float(target[0])
        tz = float(target["z"]) if isinstance(target, dict) else float(target[-1])
        return self.turn_to_yaw(yaw_towards(state.x, state.z, tx, tz))

    # --- walking -------------------------------------------------------------

    def walk_to(self, target, timeout: float | None = None,
                tolerance: float | None = None) -> MoveOutcome:
        """Walk to a position and confirm arrival by observation.

        The loop below is the whole point of the runtime. Every branch out of it
        is a fact about the world that the brain could not have known: that the
        ground gave way, that the doorway was too low, that something stopped
        the body a metre short of where the route said it could stand.
        """
        started_wall = time.monotonic()
        timeout = timeout if timeout is not None else self.config.maximum_action_seconds
        tolerance = tolerance if tolerance is not None else self.config.position_tolerance
        target_x = float(target["x"]) if isinstance(target, dict) else float(target[0])
        target_y = float(target["y"]) if isinstance(target, dict) else float(target[1])
        target_z = float(target["z"]) if isinstance(target, dict) else float(target[-1])

        try:
            state = self._state()
        except (BridgeUnavailable, BridgeRefused) as exc:
            return MoveOutcome("bridge_unavailable", False, str(exc))

        start_y = state.y
        best_distance = state.ground_distance_to({"x": target_x, "z": target_z})
        last_progress_at = time.monotonic()
        recent_positions: list[tuple[float, float]] = []

        def finish(status: str, ok: bool, reason: str, current: SelfState, extra=None) -> MoveOutcome:
            self._stop_moving()
            distance = current.ground_distance_to({"x": target_x, "z": target_z})
            return MoveOutcome(status, ok, reason, round(distance, 3), current,
                               extra or {}, time.monotonic() - started_wall,
                               self.yaw_corrections)

        while True:
            if not self.should_continue():
                return finish("operator_stopped", False, "a human stopped the run", state)

            if time.monotonic() - started_wall > timeout:
                return finish("timeout", False,
                              f"still {best_distance:.2f} nodes away after {timeout:.0f}s", state)

            try:
                state = self._state()
            except BridgeRefused as exc:
                if exc.error_code == "player_not_connected":
                    self._stop_moving()
                    return MoveOutcome("client_disconnected", False, "the client left the server")
                return finish("bridge_unavailable", False, str(exc), state)
            except BridgeUnavailable as exc:
                return finish("bridge_unavailable", False, str(exc), state)

            self.control_ticks += 1
            distance = state.ground_distance_to({"x": target_x, "z": target_z})

            # --- arrival ---------------------------------------------------
            if distance <= tolerance:
                return finish("reached", True, "arrived and confirmed by observation", state,
                              {"arrival_distance": round(distance, 3)})

            # --- things that ended the walk regardless of distance ----------
            if state.in_liquid:
                return finish("entered_liquid", False, "the body is in liquid", state)

            if state.y < start_y - 3.5:
                return finish("fell", False,
                              f"lost {start_y - state.y:.1f} nodes of height", state,
                              {"start_y": round(start_y, 2), "current_y": round(state.y, 2)})

            # --- progress ----------------------------------------------------
            if distance < best_distance - self.config.progress_epsilon:
                best_distance = distance
                last_progress_at = time.monotonic()
            elif time.monotonic() - last_progress_at > self.config.stuck_timeout_seconds:
                details = {"closest_approach": round(best_distance, 3)}
                node_ahead = self._describe_obstacle()
                if node_ahead:
                    details.update(node_ahead)
                    # A named thing in the way is a block, not a mystery.
                    return finish("blocked", False,
                                  f"stopped by {node_ahead.get('node_ahead', 'something')}",
                                  state, details)
                return finish("no_progress", False,
                              f"no ground made for {self.config.stuck_timeout_seconds:.0f}s",
                              state, details)

            # --- steer and go -------------------------------------------------
            desired = yaw_towards(state.x, state.z, target_x, target_z)
            error = angle_difference(state.yaw, desired)
            if abs(error) > math.radians(self.config.yaw_tolerance_degrees):
                # Turning and walking at once is how a bot walks in circles
                # around its target. Stop, aim, then go.
                self._stop_moving()
                radians_per_pixel = self.calibration["radians_per_pixel"]
                pixels = int(round(-error / radians_per_pixel * self.config.yaw_gain))
                self.input.move_pointer(max(-600, min(600, pixels)), 0)
                self.yaw_corrections += 1
            else:
                if "forward" not in self.input.held_keys:
                    self.input.key_down("forward")

            # A body that is on the ground, aimed correctly, holding forward and
            # not moving is up against something it can maybe step over.
            recent_positions.append((state.x, state.z))
            if len(recent_positions) > 6:
                recent_positions.pop(0)
                spread = max(math.hypot(a[0] - b[0], a[1] - b[1])
                             for a in recent_positions for b in recent_positions)
                if spread < 0.15 and state.on_ground and abs(error) < math.radians(20):
                    self.input.tap("jump", 0.08)
                    recent_positions.clear()

            time.sleep(self._tick())

    def _describe_obstacle(self) -> dict:
        """Ask the bridge what is in front of the body, if it will say.

        Best effort by design: this only ever adds detail to a failure that has
        already been decided. If perception cannot answer, the failure keeps its
        honest generic name rather than acquiring an invented cause.
        """
        try:
            observation = self.bridge.observe("minimal")
        except (BridgeUnavailable, BridgeRefused):
            return {}
        tactile = observation.get("tactile") or {}
        ahead = tactile.get("space_at_feet_ahead")
        body = tactile.get("space_at_body_ahead")
        details = {}
        if isinstance(ahead, dict) and ahead.get("name"):
            if ahead.get("walkable"):
                details["node_ahead"] = ahead["name"]
        if isinstance(body, dict) and body.get("name") and body.get("walkable"):
            details["node_at_body"] = body["name"]
        step = tactile.get("step_height_ahead")
        if isinstance(step, (int, float)):
            details["step_height_ahead"] = step
        return details

    def follow_route(self, route: list, timeout: float | None = None) -> MoveOutcome:
        """Walk a sequence of waypoints, confirming each one.

        The runtime does not re-plan. If a waypoint turns out to be unreachable
        it reports which one and stops; deciding what to do instead is the
        brain's job, and a runtime that quietly routed around the problem would
        be hiding the most interesting thing it found.
        """
        started = time.monotonic()
        overall = timeout if timeout is not None else self.config.maximum_action_seconds
        last: MoveOutcome | None = None

        for index, waypoint in enumerate(route):
            remaining = overall - (time.monotonic() - started)
            if remaining <= 0:
                return MoveOutcome("timeout", False,
                                   f"ran out of time at waypoint {index} of {len(route)}",
                                   last.distance_remaining if last else 0.0,
                                   last.final_state if last else None,
                                   {"waypoint_index": index, "waypoints": len(route)},
                                   time.monotonic() - started, self.yaw_corrections)

            # Intermediate waypoints get a looser tolerance: stopping dead on
            # each one wastes the whole route in start-stop corrections, and
            # only the last one is a place the brain actually meant.
            is_last = index == len(route) - 1
            tolerance = self.config.position_tolerance if is_last else max(
                self.config.position_tolerance, 1.0)
            last = self.walk_to(waypoint, timeout=min(remaining, self.config.maximum_action_seconds),
                                tolerance=tolerance)
            if not last.ok:
                last.details.update({"waypoint_index": index, "waypoints": len(route)})
                return last

        if last is None:
            return MoveOutcome("unknown", False, "the route had no waypoints")
        last.details.update({"waypoints": len(route)})
        return last

    def jump(self) -> None:
        self.input.tap("jump", 0.09)

    def metrics(self) -> dict:
        return {
            "control_ticks": self.control_ticks,
            "yaw_corrections": self.yaw_corrections,
            "yaw_radians_per_pixel": round(self.calibration["radians_per_pixel"], 6),
            "yaw_calibration_source": self.calibration["source"],
        }
