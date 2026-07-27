#!/usr/bin/env python3
"""Print a TestKit JSON report summary and every non-PASS result."""
import glob
import json
import os
import sys


def main() -> int:
    if len(sys.argv) > 1:
        path = sys.argv[1]
    else:
        reports = sorted(glob.glob("data/worlds/perfectworld/ltk_report_*.json"),
                         key=os.path.getmtime)
        if not reports:
            print("no report found")
            return 1
        path = reports[-1]

    with open(path) as handle:
        report = json.load(handle)

    summary = report["summary"]
    print(f"report: {os.path.basename(path)}")
    print(f"started: {report.get('started_at')}  finished: {report.get('finished_at')}")
    print("{total} total | {passed} PASS | {failed} FAIL | {skipped} SKIP | {errors} ERROR".format(**summary))

    for result in report["results"]:
        if result["status"] != "PASS":
            print(f"  {result['status']} | {result['suite']}.{result['name']}: {result['message']}")
            for line in result.get("details") or []:
                print(f"      {line}")
    return 0 if summary["failed"] == 0 and summary["errors"] == 0 and summary["skipped"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
