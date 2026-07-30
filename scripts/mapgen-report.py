#!/usr/bin/env python3
"""Turn a pw_mapgen_probe report into a table a person can argue with.

Exits non-zero when more than a third of the candidates walked to produced
nothing, because that is the condition the report exists to catch.
"""
import collections
import json
import sys


def main(path):
    with open(path) as handle:
        data = json.load(handle)
    probes = data.get("probes") or []
    if not probes:
        print("no candidates in the report")
        return 1

    print(f"{'id':44} {'type':8} {'x':>7} {'z':>7} {'lots':>5}  result")
    print("-" * 88)
    for p in probes:
        if p.get("placed_before"):
            result = "already standing"
        elif p.get("built"):
            result = "built %d" % p.get("buildings", 0)
        elif p.get("placed_after"):
            # The site is spent but nothing stands on it: the plan failed and
            # the candidate was marked placed so no later mapchunk replans the
            # same hopeless ground. Not a building.
            result = "NOTHING (%s)" % (p.get("refusal") or p.get("status") or "no reason recorded")
        else:
            result = "NOTHING (%s)" % (p.get("refusal") or "no reason recorded")
        lots = p.get("lots")
        print(f"{p.get('id', '?'):44} {p.get('type', '?'):8} "
              f"{p.get('x', 0):7} {p.get('z', 0):7} "
              f"{(lots if lots is not None else ''):>5}  {result}")

    fresh = [p for p in probes if not p.get("placed_before")]
    built = [p for p in fresh if p.get("built")]
    by_type = collections.defaultdict(lambda: [0, 0])
    for p in fresh:
        slot = by_type[p.get("type", "?")]
        slot[0] += 1
        if p.get("built"):
            slot[1] += 1

    print()
    print(f"walked to {len(probes)}, of which {len(fresh)} had nothing there yet")
    print(f"built {len(built)}, left empty {len(fresh) - len(built)}")
    for kind in sorted(by_type):
        asked, ok = by_type[kind]
        print(f"  {kind:8} {ok}/{asked}  ({ok / asked * 100:.0f}%)")

    refusals = collections.Counter(
        p.get("refusal") or "no reason recorded"
        for p in fresh if not p.get("built"))
    if refusals:
        print("why nothing was built:")
        for reason, count in refusals.most_common():
            print(f"  {count:3}  {reason}")

    lots = [p["lots"] for p in built if p.get("lots")]
    if lots:
        print(f"lots per settlement that has any: min {min(lots)}, "
              f"median {sorted(lots)[len(lots) // 2]}, max {max(lots)}")

    if fresh and len(built) / len(fresh) < 2 / 3:
        print("\nFAIL: more than a third of what the planner promised was never built")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
