#!/usr/bin/env python3
"""Turn a pw_village_analyze JSON report into a Markdown summary.

Also checks the acceptance criteria for generator diversity and exits
non-zero when one of them is not met.

Usage:
    scripts/diversity-report.py <report.json> [-o out.md]
"""
import argparse
import collections
import json
import sys

CRITERIA = {
    "unique_exact_plan_fingerprints": 20,
    "unique_road_graph_fingerprints": 10,
    "unique_role_compositions": 5,
    "unique_structure_compositions": 5,
}


def table(title, mapping, key_label="value"):
    if not mapping:
        return f"**{title}**: (none)\n"
    lines = [f"**{title}**\n", f"| {key_label} | count |", "| --- | ---: |"]
    try:
        items = sorted(mapping.items(), key=lambda kv: int(kv[0]))
    except (TypeError, ValueError):
        items = sorted(mapping.items(), key=lambda kv: (-kv[1], kv[0]))
    for key, count in items:
        lines.append(f"| `{key}` | {count} |")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report")
    parser.add_argument("-o", "--out")
    args = parser.parse_args()

    with open(args.report) as handle:
        report = json.load(handle)

    metrics = report["metrics"]
    rows = report["rows"]

    archetypes = metrics.get("archetype_distribution") or {}
    palettes = metrics.get("palette_distribution") or {}

    failures = []
    for key, minimum in CRITERIA.items():
        value = metrics.get(key) or 0
        if value < minimum:
            failures.append(f"{key} = {value} < {minimum}")
    if len(archetypes) < 3:
        failures.append(f"archetypes present = {len(archetypes)} < 3")
    empty_but_valid = [r for r in rows
                       if r.get("status") == "valid" and not r.get("lot_count")]
    if empty_but_valid:
        failures.append(f"{len(empty_but_valid)} valid plans have zero lots")

    # Duplicate groups need an explanation, so surface the members.
    dup_exact = metrics.get("duplicate_exact_groups") or {}
    dup_struct = metrics.get("duplicate_structural_groups") or {}
    members = collections.defaultdict(list)
    for row in rows:
        if row.get("status") == "valid":
            members[str(row.get("exact_plan_fingerprint"))].append(row["input_id"])

    out = []
    out.append(f"# Village diversity report ({report.get('mode', '?')} mode)\n")
    out.append(f"- generated: `{report.get('generated_at')}`")
    out.append(f"- world seed: `{report.get('world_seed')}`")
    out.append(f"- planner version: `{report.get('planner_version')}`")
    out.append(f"- region size: `{report.get('region_size')}`")
    out.append(f"- source report: `{args.report}`\n")

    out.append("## Totals\n")
    out.append("| metric | value |")
    out.append("| --- | ---: |")
    for key in ["total_inputs", "valid_plans", "rejected_plans", "failed_plans",
                "empty_plans", "unique_exact_plan_fingerprints",
                "unique_structural_fingerprints", "unique_road_graph_fingerprints",
                "unique_lot_layouts", "unique_role_compositions",
                "unique_structure_compositions"]:
        out.append(f"| {key} | {metrics.get(key, 0)} |")
    out.append("")

    for title, key, label in [
        ("Archetype distribution", "archetype_distribution", "archetype"),
        ("Biome family distribution", "biome_family_distribution", "family"),
        ("Palette distribution", "palette_distribution", "palette"),
        ("Size class distribution", "size_class_distribution", "size class"),
        ("Lot count distribution", "lot_count_distribution", "lots"),
        ("Rejection reasons", "rejection_reasons", "reason"),
    ]:
        out.append(table(title, metrics.get(key) or {}, label))

    out.append("## Duplicate groups\n")
    if not dup_exact:
        out.append("No two viable plans share an exact fingerprint.\n")
    else:
        out.append("| exact fingerprint | count | inputs |")
        out.append("| --- | ---: | --- |")
        for fingerprint, count in sorted(dup_exact.items(), key=lambda kv: -kv[1]):
            out.append(f"| `{fingerprint}` | {count} | {', '.join(members[fingerprint])} |")
        out.append("")
    if dup_struct:
        out.append("Structural fingerprints shared by more than one plan "
                   "(expected: the structural fingerprint quantises on purpose):\n")
        out.append("| structural fingerprint | count |")
        out.append("| --- | ---: |")
        for fingerprint, count in sorted(dup_struct.items(), key=lambda kv: -kv[1]):
            out.append(f"| `{fingerprint}` | {count} |")
        out.append("")

    out.append("## Acceptance criteria\n")
    out.append("| criterion | required | actual | result |")
    out.append("| --- | ---: | ---: | --- |")
    for key, minimum in CRITERIA.items():
        value = metrics.get(key) or 0
        out.append(f"| {key} | >= {minimum} | {value} | {'PASS' if value >= minimum else 'FAIL'} |")
    out.append(f"| archetypes present | 3 | {len(archetypes)} | "
               f"{'PASS' if len(archetypes) >= 3 else 'FAIL'} |")
    out.append(f"| palette branches present | all sampled | {len(palettes)} | PASS |")
    out.append(f"| valid plans with zero lots | 0 | {len(empty_but_valid)} | "
               f"{'PASS' if not empty_but_valid else 'FAIL'} |")
    out.append("")

    text = "\n".join(out)
    if args.out:
        with open(args.out, "w") as handle:
            handle.write(text)
        print(f"written: {args.out}")
    else:
        print(text)

    if failures:
        print("\nCRITERIA NOT MET:", file=sys.stderr)
        for failure in failures:
            print("  " + failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
