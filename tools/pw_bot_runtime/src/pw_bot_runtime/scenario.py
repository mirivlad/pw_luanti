"""Scripted acceptance scenarios: a test harness that stands in for the brain.

**This is not the bot deciding.** In a normal run the brain publishes intents and
the runtime executes them; nothing here is on that path. What this module does is
build the same ``pw_player_bot/v1`` intent documents by hand, so an acceptance
test can say "walk *there*, then open *that* door" and get a deterministic answer
about whether a real client could.

It exists because free exploration is the wrong instrument for two questions:

* *can the body do this at all?* — free exploration might never try the door;
* *does the runtime report failure honestly?* — the obstacles that must fail
  have to actually be attempted, on purpose, every run.

The intents produced here go through exactly the same executor, movement
controller and interaction controller as the brain's. Only the author differs.
"""

from __future__ import annotations

import json
from pathlib import Path

from .intent_client import Intent, parse_intent

PROTOCOL = "pw_player_bot/v1"


def make_intent(intent_id: str, goal: str, steps: list, note: str = "") -> Intent:
    """Build a valid intent document by hand and parse it like any other."""
    document = {
        "protocol": PROTOCOL,
        "intent_id": intent_id,
        "player_name": "scenario",
        "issued_tick": 0,
        "goal": {"kind": goal, "score": 1.0, "note": note or goal},
        "alternatives": [],
        "rationale": [f"scenario step: {note or goal}"],
        "plan": {"kind": "route", "route": [], "route_length": 0,
                 "steps": steps, "reason": "written by the acceptance harness"},
        "constraints": {"max_step_up": 1, "max_step_down": 3,
                        "avoid": ["hazard", "lava"], "route_is_belief_only": False},
        "expires_after_ticks": 10,
        "executed_by": "pw_bot_runtime acceptance harness",
    }
    return parse_intent(document)


def walk(intent_id: str, position: dict, note: str) -> Intent:
    return make_intent(intent_id, "scenario_walk",
                       [{"action": "walk_to", "position": position}], note)


def load_course(path: str | Path) -> dict:
    """Read the landmarks pw_debug wrote when it built the course."""
    document = json.loads(Path(path).read_text(encoding="utf-8"))
    return document["landmarks"]


class ScenarioStep:
    """One expectation: an intent, and what it is allowed to end as."""

    def __init__(self, name: str, intent: Intent, expect_ok: bool,
                 expect_status: tuple[str, ...] = (), required: bool = True,
                 note: str = "") -> None:
        self.name = name
        self.intent = intent
        self.expect_ok = expect_ok
        self.expect_status = expect_status
        self.required = required
        self.note = note

    def judge(self, status: str, ok: bool) -> tuple[bool, str]:
        if self.expect_status and status not in self.expect_status:
            return False, (f"expected one of {', '.join(self.expect_status)}, got {status}")
        if ok != self.expect_ok:
            return False, f"expected ok={self.expect_ok}, got ok={ok} ({status})"
        return True, status


def course_scenario(landmarks: dict) -> list[ScenarioStep]:
    """The obstacle course, in order, including everything that must fail.

    The second half is the important half. Any runtime can report success; a
    runtime worth trusting reports ``blocked`` when a wall is two nodes high and
    says which node stopped it.
    """
    steps: list[ScenarioStep] = []

    def add(name, intent, ok, statuses, note, required=True):
        steps.append(ScenarioStep(name, intent, ok, statuses, required, note))

    add("walk_straight", walk("scn-1", landmarks["straight"], "flat ground, straight ahead"),
        True, ("reached",), "the simplest thing a body can do")

    # Two legs, because the runtime walks straight lines. Routing round the
    # wall is the brain's job, and a harness that skipped the intermediate
    # waypoint would be testing a pathfinder the runtime is not allowed to have.
    add("turn_corner",
        make_intent("scn-2", "scenario_walk",
                    [{"action": "follow_route",
                      "route": [landmarks["corner_approach"], landmarks["corner"]],
                      "length": 2}],
                    "aside, then on"),
        True, ("reached",), "the way ahead is walled; the way on is to the left")

    add("step_up", walk("scn-3", landmarks["step_up"], "one node up"),
        True, ("reached",), "a kerb within the step limit")

    add("climb_stairs", walk("scn-4", landmarks["stairs_top"], "up three stairs"),
        True, ("reached",), "one node per tread, contiguous")

    add("open_door",
        make_intent("scn-5", "scenario_interact",
                    [{"action": "interact", "position": landmarks["door"]}],
                    "right-click the door"),
        True, ("reached",), "the game opens it because a player clicked it")

    add("enter_room", walk("scn-6", landmarks["room_centre"], "into the room"),
        True, ("reached",), "through the doorway the click opened")

    # A door is one shape of "click it and the world answers". A runtime that
    # can only open doors has not been shown to interact — it has been shown to
    # open doors. These two are optional so that a game without a fence gate or
    # a hand-openable trapdoor does not fail the course for lacking one.
    for index, (name, landmark, note) in enumerate((
        ("open_gate", "gate", "a fence gate beside the room's centre"),
        ("open_trapdoor", "trapdoor", "a trapdoor on the other side"),
    )):
        if landmarks.get(landmark):
            add(name,
                make_intent(f"scn-6{index}", "scenario_interact",
                            [{"action": "interact", "position": landmarks[landmark]}],
                            f"right-click the {landmark}"),
                True, ("reached",), note, required=False)

    add("leave_room", walk("scn-7", landmarks["room_exit"], "out of the room"),
        True, ("reached",), "and out the other side")

    # --- everything below must fail, and must fail for the stated reason ---

    add("refuse_too_high", walk("scn-8", landmarks["too_high"], "a two-node threshold"),
        False, ("blocked", "no_progress", "timeout"),
        "too high to climb: reporting success here would be a lie")

    add("refuse_low_beam", walk("scn-9", landmarks["low_beam"], "a beam at head height"),
        False, ("blocked", "no_progress", "timeout"),
        "the feet fit and the head does not")

    add("refuse_pit", walk("scn-10", landmarks["pit"], "a pit"),
        False, ("blocked", "no_progress", "timeout", "fell"),
        "either it stops at the edge or it falls in, and both are honest")

    add("water_is_noticed", walk("scn-11", landmarks["water"], "water"),
        False, ("entered_liquid", "blocked", "no_progress", "timeout"),
        "wading is not walking", required=False)

    add("refuse_dead_end", walk("scn-12", landmarks["dead_end"], "a dead end"),
        False, ("blocked", "no_progress", "timeout"),
        "sealed to the ceiling")

    return steps


def village_scenario(waypoints: dict) -> list[ScenarioStep]:
    """A generated village: street, dwelling, door, inside, back out.

    Takes whatever the caller found in the real world, because a village is not
    built to order and its landmarks have to be discovered rather than assumed.
    """
    steps: list[ScenarioStep] = []
    order = [
        ("walk_the_street", "street", True, ("reached",), "along the street"),
        ("reach_the_dwelling", "dwelling", True, ("reached",), "up to the building"),
        ("approach_the_entrance", "entrance", True, ("reached",), "onto the doorstep"),
    ]
    for name, key, ok, statuses, note in order:
        if waypoints.get(key):
            steps.append(ScenarioStep(name, walk(f"vil-{name}", waypoints[key], note),
                                      ok, statuses, True, note))
    if waypoints.get("door"):
        steps.append(ScenarioStep(
            "open_the_door",
            make_intent("vil-door", "scenario_interact",
                        [{"action": "interact", "position": waypoints["door"]}],
                        "right-click the dwelling's door"),
            True, ("reached",), True, "a real door in a generated village"))
    for name, key, note in (("go_inside", "inside", "into the dwelling"),
                            ("come_back_out", "outside", "and back onto the street")):
        if waypoints.get(key):
            steps.append(ScenarioStep(name, walk(f"vil-{name}", waypoints[key], note),
                                      True, ("reached",), True, note))
    return steps


SCENARIOS = {"course": course_scenario, "village": village_scenario}
