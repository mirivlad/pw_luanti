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

import math
import time
from dataclasses import dataclass, field

from .bridge_client import BridgeClient
from .errors import BridgeRefused, BridgeUnavailable
from .input_backend import InputBackend, InputBackendError
from .movement import MovementController

#: How far a player can reach. Luanti's default hand range is 4 nodes; the
#: runtime stays inside it rather than discovering the limit by failing.
REACH_NODES = 4.0

#: Eye height above the reported feet position, in nodes.
EYE_HEIGHT = 1.625

#: A door is two nodes tall and clicking either half works, so the crosshair
#: landing one node above or below the named position is still the door.
TARGET_VERTICAL_SLACK = 1

#: Hotbar slots to try, in order, when looking for an empty hand.
#:
#: What is held decides what "use" means. With a *throwable* in hand the item's
#: own handler runs and the pointed node is never asked; with a *block* the
#: engine may place it instead. Only an empty hand reliably means "use the thing
#: I am looking at".
#:
#: Which slot is empty is a property of the player, not of the code. Two
#: successive guesses at a permanently-empty slot were both wrong on this
#: server's test player — slot 8 held a block, and so did slot 5 — so the
#: runtime stopped guessing: it selects a slot, asks the bridge what is now in
#: hand, and moves on until the answer is "nothing".
HOTBAR_SLOTS = (5, 4, 3, 6, 7, 8, 9, 2, 1)

#: How many times to press "use" before calling an interaction ineffective.
#: Each attempt is checked against the world, so a retry cannot turn a real
#: failure into a reported success — it only covers a press the client's frame
#: loop never sampled.
INTERACT_ATTEMPTS = 3


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

    def _wielded(self) -> str | None:
        """What the bridge says is in the bot's hand, or None if it cannot say.

        Read from the parsed field rather than out of the raw envelope: the
        first version of this reached into the whole response for a key that
        lives inside its ``self_state`` object, got ``None`` every time, and
        reported an empty hand without ever having checked one.
        """
        try:
            return self.bridge.self_state().wielded_item
        except (BridgeUnavailable, BridgeRefused):
            return None

    def _empty_hand(self) -> tuple[bool, str]:
        """Select hotbar slots until the bridge reports an empty hand.

        Returns whether the hand ended up empty, and what is in it. A hand that
        cannot be emptied is not fatal — the interaction is still attempted, and
        what was held is recorded so a failure can be read afterwards rather
        than guessed at.
        """
        held = self._wielded()
        if held is None:
            return False, "unknown"
        if held == "":
            return True, ""
        for slot in HOTBAR_SLOTS:
            try:
                self.input.select_hotbar_slot(slot)
            except InputBackendError:
                continue
            time.sleep(0.15)
            held = self._wielded()
            if held == "":
                return True, ""
            if held is None:
                return False, "unknown"
        return False, held

    # --- looking at the thing ------------------------------------------------

    def _target_under_crosshair(self) -> dict:
        try:
            return self.bridge.inspect_target() or {}
        except (BridgeUnavailable, BridgeRefused):
            return {}

    def _observed_state(self, position) -> dict:
        """What the bridge can see at a position: its feature tags and its node.

        The bridge does not report a door's state as a field — it reports it as
        a *semantic tag*, ``door_open`` or ``door_closed``, alongside the plain
        ``door`` tag, and a position carries one feature entry per tag. So the
        thing to compare across a click is the set of tags at that position.

        Uses player-mode perception only. The runtime never asks the oracle: it
        stands in for a player, and a player cannot see through a door to check
        whether their click worked.
        """
        tags: set[str] = set()
        node_name = ""
        try:
            observation = self.bridge.observe("detailed")
        except (BridgeUnavailable, BridgeRefused):
            observation = {}

        wanted = (round(float(position["x"])), round(float(position["y"])),
                  round(float(position["z"])))
        for feature in observation.get("visible_features") or []:
            spot = feature.get("position") or {}
            if not spot:
                continue
            here = (round(float(spot.get("x", 0))), round(float(spot.get("y", 0))),
                    round(float(spot.get("z", 0))))
            if (here[0], here[2]) == (wanted[0], wanted[2]) \
                    and abs(here[1] - wanted[1]) <= TARGET_VERTICAL_SLACK:
                tags.add(str(feature.get("feature")))
                node_name = node_name or str(feature.get("node_name") or "")

        # A door leaf can fall outside the feature sweep — it is a ray fan, not
        # an index. What the crosshair is on is a second, independent look at
        # the same question, and it is exactly where the click will land.
        crosshair = self._target_under_crosshair()
        node = (crosshair.get("target") or {}).get("node") or {}
        crosshair_position = node.get("position") or {}
        if crosshair_position:
            here = (round(float(crosshair_position.get("x", 0))),
                    round(float(crosshair_position.get("y", 0))),
                    round(float(crosshair_position.get("z", 0))))
            if (here[0], here[2]) == (wanted[0], wanted[2]) \
                    and abs(here[1] - wanted[1]) <= TARGET_VERTICAL_SLACK:
                node_name = node_name or str(node.get("name") or "")
                for tag in node.get("semantics") or []:
                    tags.add(str(tag))

        return {"tags": tags, "node_name": node_name}

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

        on_target, pitch_error, crosshair = self._aim_until_on_target(target)
        if not on_target:
            return InteractionOutcome(
                "blocked", False, "could not get the crosshair onto the target",
                {"diagnosis": "could_not_aim", "distance": round(distance, 2),
                 "pitch_error_degrees": round(math.degrees(pitch_error), 2),
                 "crosshair": _crosshair_summary(crosshair)})

        before = self._observed_state(target)
        if not before["tags"] and not before["node_name"]:
            return InteractionOutcome(
                "blocked", False, "nothing recognisable is under the crosshair",
                {"diagnosis": "target_not_visible", "distance": round(distance, 2),
                 "pitch_error_degrees": round(math.degrees(pitch_error), 2),
                 "crosshair": _crosshair_summary(self._target_under_crosshair())})

        already_open = "door_open" in before["tags"] or "gate_open" in before["tags"]

        # Start from a clean keyboard. A held sneak changes what "use" means:
        # the engine calls the pointed node's `on_rightclick` only when the
        # player is *not* sneaking, and otherwise places whatever is in hand
        # instead. That is exactly what the server log recorded — the bot put a
        # block down at the doorstep instead of opening the door in front of it —
        # and with an empty hand the same state makes the press do nothing at
        # all. Whatever left a key down, an interaction should not inherit it.
        released = self.input.release_all()

        hand_empty, held = self._empty_hand()

        # A key, and deliberately without touching the pointer.
        #
        # Luanti turns the head from *relative* pointer motion, and on a bare
        # Xvfb with no window manager the client never grabs the pointer — which
        # is the whole reason place is bound to a key here. So any warp, even one
        # aimed at the middle of the client's own window, arrives as a large
        # mouse movement and swings the view off the target in the moment
        # between aiming and pressing. Aim, then press, and leave the pointer
        # where it lies.
        aimed_at = self._target_under_crosshair()

        # Press, then look; repeat while nothing has happened.
        #
        # Luanti reads "place" as a *held state*, once per rendered frame. The
        # client here draws through software GL on an Xvfb display, where a frame
        # can take longer than a brief tap — so a press and release can fall
        # entirely between two frames and be missed, silently and intermittently.
        # Holding longer is not free either: `repeat_place_time` defaults to a
        # quarter second, and a hold past it fires twice, which on a door means
        # open-then-closed and looks exactly like nothing happening.
        #
        # So the press is held long enough to span a slow frame and short enough
        # not to repeat, and the outcome is checked after each attempt rather
        # than assumed. Attempts stop the moment the world answers.
        after = before
        for attempt in range(INTERACT_ATTEMPTS):
            self.input.use()
            self.interactions += 1
            # Mineclonia animates the leaf and the server has to tell us about it.
            time.sleep(0.7)
            after = self._observed_state(target)
            if after["tags"] != before["tags"] or after["node_name"] != before["node_name"]:
                break
            if self.log and attempt + 1 < INTERACT_ATTEMPTS:
                self.log.info("interact: nothing changed, pressing again (%d of %d)",
                              attempt + 2, INTERACT_ATTEMPTS)

        details = {
            "before_tags": sorted(before["tags"]),
            "after_tags": sorted(after["tags"]),
            "before_node": before["node_name"],
            "after_node": after["node_name"],
            "distance": round(distance, 2),
            # What the crosshair was actually on at the instant of the press.
            # When an interaction fails this is the first thing worth seeing:
            # aiming at the right node and pressing at the wrong one looks
            # identical from the outside.
            "aimed_at": _crosshair_summary(aimed_at),
            "hand_empty": hand_empty,
            "held": held,
            "keys_released_first": released,
        }

        if expect != "state_change":
            return InteractionOutcome("reached", True, "clicked", details)

        if already_open:
            # Clicking an open door closes it, which is a state change and also
            # not what was wanted. Either way the door answered to a click.
            return InteractionOutcome(
                "reached", True, "the door was already open when the bot arrived",
                {**details, "diagnosis": "already_open"})

        opened = "door_open" in after["tags"] or "gate_open" in after["tags"]
        closed_before = "door_closed" in before["tags"] or "gate_closed" in before["tags"]
        if opened and closed_before:
            return InteractionOutcome(
                "reached", True, "the door opened", {**details, "diagnosis": "door_opened"})

        if before["tags"] != after["tags"] and after["tags"]:
            return InteractionOutcome(
                "reached", True,
                f"what the bridge sees changed: {sorted(before['tags'])} -> {sorted(after['tags'])}",
                {**details, "diagnosis": "observed_state_changed"})

        if before["node_name"] and after["node_name"] and before["node_name"] != after["node_name"]:
            return InteractionOutcome(
                "reached", True,
                f"the node changed from {before['node_name']} to {after['node_name']}",
                {**details, "diagnosis": "node_changed"})

        if not after["tags"] and not after["node_name"]:
            return InteractionOutcome(
                "unknown", False, "the target is no longer observable after the click",
                {**details, "diagnosis": "target_disappeared"})

        return InteractionOutcome(
            "blocked", False, "the click changed nothing the bridge can see",
            {**details, "diagnosis": "interaction_had_no_effect"})

    def _aim_pitch_at(self, target) -> float:
        """Point the head at the target's height as well as its bearing."""
        try:
            state = self.bridge.self_state()
        except (BridgeUnavailable, BridgeRefused):
            return 0.0
        horizontal = ((target["x"] - state.x) ** 2 + (target["z"] - state.z) ** 2) ** 0.5
        if horizontal < 1e-6:
            return 0.0
        wanted = math.atan2(target["y"] - (state.y + EYE_HEIGHT), horizontal)
        return self.movement.look_at_pitch(wanted)

    def _crosshair_is_on(self, target) -> tuple[bool, dict]:
        """Is the crosshair on the target's column, within a node either way?"""
        crosshair = self._target_under_crosshair()
        # The position of what was hit belongs to the *target*, not to the node
        # description nested inside it. Reading it from the node gave None every
        # time, and the aim check then rejected a crosshair that was sitting on
        # the door and naming it correctly.
        target_document = (crosshair.get("target") or {})
        spot = target_document.get("position") or {}
        if not spot:
            return False, crosshair
        here = (round(float(spot.get("x", 0))), round(float(spot.get("y", 0))),
                round(float(spot.get("z", 0))))
        wanted = (round(float(target["x"])), round(float(target["y"])),
                  round(float(target["z"])))
        return ((here[0], here[2]) == (wanted[0], wanted[2])
                and abs(here[1] - wanted[1]) <= TARGET_VERTICAL_SLACK), crosshair

    def _aim_until_on_target(self, target) -> tuple[bool, float, dict]:
        """Aim at the target, check, and try its other levels if that missed.

        Aiming once and trusting the arithmetic is what put the crosshair on the
        floor. A door is named by its lower node, and standing on the doorstep
        that node is more than a metre below eye level barely a metre away — so
        "look at the target" resolves to looking almost straight down, and the
        ray strikes the floor at the bot's own feet long before it reaches the
        door.

        A person opening a door looks at the door, roughly level. So the levels
        are tried nearest-to-eye-height first, and each attempt is checked
        against what the crosshair actually reports rather than assumed.
        """
        self.movement.face_position(target)
        try:
            eye_y = self.bridge.self_state().y + EYE_HEIGHT
        except (BridgeUnavailable, BridgeRefused):
            eye_y = float(target["y"])

        # A door occupies its named node and the one above it. Sort the
        # candidate heights by how close each is to level with the eyes.
        levels = sorted((target["y"] + offset for offset in (1, 0, 2)),
                        key=lambda y: abs(y - eye_y))
        pitch_error = 0.0
        crosshair: dict = {}
        for level in levels:
            aim = {"x": target["x"], "y": level, "z": target["z"]}
            pitch_error = self._aim_pitch_at(aim)
            time.sleep(0.15)
            on_target, crosshair = self._crosshair_is_on(target)
            if on_target:
                return True, pitch_error, crosshair
        return False, pitch_error, crosshair

    def metrics(self) -> dict:
        return {"interactions": self.interactions}


def _crosshair_summary(document) -> dict:
    """What the crosshair is on, for a failure that needs explaining."""
    target = (document or {}).get("target") or {}
    node = target.get("node") or {}
    return {
        "node": node.get("name"),
        # `position` is a field of the target, not of the node description
        # nested in it. Reading it from the node reported null on every hit and
        # made a correct crosshair look like a miss.
        "position": target.get("position"),
        "distance": target.get("distance"),
        "semantics": node.get("semantics"),
    }
