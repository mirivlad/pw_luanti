#!/usr/bin/env python3
"""Render a pw_village_export JSON as a Markdown acceptance table.

Exits non-zero when a built settlement fails physical validation.

Usage:
    scripts/settlement-report.py <pw_settlements_*.json> [-o out.md]
"""
import argparse
import json
import sys

FIELDS = [
    ("settlement_id", "settlement_id"),
    ("candidate_id", "candidate_id"),
    ("region_id", "region_id"),
    ("status", "status"),
    ("archetype", "archetype"),
    ("size_class", "size_class"),
    ("biome_name", "biome_name"),
    ("biome_family", "biome_family"),
    ("palette_id", "palette"),
    ("lot_count", "lot_count"),
    ("planned_lot_count", "planned_lots"),
    ("road_segment_count", "road_segments"),
    ("exact_plan_fingerprint", "exact_plan_fingerprint"),
    ("structural_fingerprint", "structural_fingerprint"),
    ("road_graph_fingerprint", "road_graph_fingerprint"),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report")
    parser.add_argument("-o", "--out")
    args = parser.parse_args()

    with open(args.report) as handle:
        data = json.load(handle)

    settlements = data["settlements"]
    built = [s for s in settlements if (s.get("lot_count") or 0) > 0]
    failed = [s for s in settlements if (s.get("lot_count") or 0) == 0]
    invalid = [s for s in built if not s["validation"]["ok"]]

    out = ["# Materialized settlements\n"]
    out.append(f"- generated: `{data.get('generated_at')}`")
    out.append(f"- world seed: `{data.get('world_seed')}`")
    out.append(f"- planner version: `{data.get('planner_version')}`")
    out.append(f"- records: {len(settlements)} "
               f"(built {len(built)}, rejected sites {len(failed)})")
    out.append(f"- physical validation: {len(built) - len(invalid)}/{len(built)} pass\n")

    out.append("## Coverage\n")
    for key, label in [("archetype", "Archetype"), ("biome_family", "Biome family"),
                       ("palette_id", "Palette"), ("size_class", "Size class")]:
        counts = {}
        for settlement in built:
            counts[str(settlement.get(key))] = counts.get(str(settlement.get(key)), 0) + 1
        rendered = ", ".join(f"`{k}` x{v}" for k, v in sorted(counts.items()))
        out.append(f"- {label}: {rendered}")
    out.append("")

    out.append("## Built settlements\n")
    for settlement in built:
        out.append(f"### {settlement['settlement_id']}\n")
        for key, label in FIELDS:
            out.append(f"- {label}: `{settlement.get(key)}`")
        center = settlement.get("center_pos") or {}
        bounds = settlement.get("bounds") or {}
        out.append(f"- center: `({center.get('x')}, {center.get('y')}, {center.get('z')})`")
        out.append("- bounds: `({}, {})..({}, {})`".format(
            bounds.get("min_x"), bounds.get("min_z"),
            bounds.get("max_x"), bounds.get("max_z")))
        env = settlement.get("environment_profile") or {}
        out.append("- environment profile: "
                   f"`elevation={env.get('elevation')} roughness={env.get('roughness')} "
                   f"water_proximity={env.get('water_proximity')} "
                   f"vegetation_density={env.get('vegetation_density')} "
                   f"heat={env.get('heat')} humidity={env.get('humidity')}`")
        out.append(f"- required roles: `{', '.join(settlement.get('required_roles') or [])}`")
        out.append(f"- optional roles: `{', '.join(settlement.get('optional_roles') or [])}`")
        out.append(f"- role counts: `{settlement.get('role_counts')}`")
        out.append(f"- structure ids: `{', '.join(settlement.get('structure_ids') or [])}`")
        out.append(f"- structure variants: `{', '.join(settlement.get('structure_variants') or [])}`")
        out.append(f"- road ids: `{', '.join(settlement.get('road_ids') or [])}`")
        validation = settlement["validation"]
        out.append(f"- validation: `{'PASS' if validation['ok'] else 'FAIL'}`")
        checks = validation.get("checks") or {}
        for name in sorted(checks):
            out.append(f"  - {name}: `{checks[name]}`")
        if validation.get("issues"):
            out.append(f"  - issues: `{', '.join(validation['issues'])}`")
        out.append("")

    if failed:
        out.append("## Rejected sites (status=failed, nothing built)\n")
        out.append("| settlement_id | archetype | biome family | reason | rejections |")
        out.append("| --- | --- | --- | --- | --- |")
        for settlement in failed:
            out.append("| `{}` | `{}` | `{}` | `{}` | `{}` |".format(
                settlement["settlement_id"], settlement.get("archetype"),
                settlement.get("biome_family"), settlement.get("reason"),
                settlement.get("rejections")))
        out.append("")

    text = "\n".join(out)
    if args.out:
        with open(args.out, "w") as handle:
            handle.write(text)
        print(f"written: {args.out}")
    else:
        print(text)

    if invalid:
        print("\nVALIDATION FAILURES:", file=sys.stderr)
        for settlement in invalid:
            print(f"  {settlement['settlement_id']}: "
                  f"{', '.join(settlement['validation']['issues'])}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
