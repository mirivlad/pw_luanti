#!/usr/bin/env python3
"""Summarise a pw_accessibility_report JSON into a table.

The number that matters is unreachable doors. Everything else is there so that
a zero can be told apart from a zero that was never measured: a run over three
settlements proves nothing, and a run where nothing materialized proves less.
"""
import json
import sys


def main(path):
    report = json.load(open(path))
    rows = report["settlements"]
    totals = report["totals"]

    built = [r for r in rows if r["materialized_lots"] > 0]
    print(f"world seed {report.get('world_seed')}   {report.get('generated_at')}")
    print()
    print(f"{'settlement':<26} {'name':<16} {'kind':<9} {'status':<9} "
          f"{'lots':>5} {'built':>6} {'no route':>9}")
    print("-" * 88)
    for r in sorted(rows, key=lambda r: (-r["unreachable_doors"], r["id"])):
        if r["materialized_lots"] == 0 and r["status"] == "failed":
            continue
        print(f"{r['id']:<26} {str(r['name'])[:16]:<16} "
              f"{str(r.get('settlement_type'))[:9]:<9} {str(r['status']):<9} "
              f"{r['lot_count']:>5} {r['materialized_lots']:>6} "
              f"{r['unreachable_doors']:>9}")

    print()
    print(f"settlements in the report : {totals['settlements']}")
    print(f"  with something built    : {len(built)}")
    print(f"  complete / partial / failed: {totals.get('complete', 0)} / "
          f"{totals.get('partial', 0)} / {totals.get('failed', 0)}")
    print(f"lots planned              : {totals['lots']}")
    print(f"lots materialized         : {totals['materialized']}")
    print(f"doors with no walkable route: {totals['unreachable']}")

    rescues = totals.get("rescues") or {}
    if rescues:
        print()
        print("rescue routes that were needed:")
        for name, count in sorted(rescues.items(), key=lambda kv: -kv[1]):
            print(f"  {name:<20} {count}")
    else:
        print()
        print("no rescue route was needed at all")

    if totals["unreachable"]:
        print()
        print("unreachable buildings:")
        for r in rows:
            for sid in r.get("unreachable_ids") or []:
                print(f"  {r['id']}  {sid}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
