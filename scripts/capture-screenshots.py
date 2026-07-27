#!/usr/bin/env python3
"""Capture village screenshots from the running pwbot client.

Reads a shot list produced by /pw_village_shotlist, drives the camera through
pw_remote_control, and grabs the Xvfb root window with ImageMagick's `import`.

The client is a real Luanti client, so each move needs time for the server to
send the mapblocks and for the client to build the meshes; --settle controls
that wait.

Usage:
    scripts/capture-screenshots.py --shotlist <file.json> --out <dir> [--limit 6]
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

WORLD = "data/worlds/perfectworld"


def find_client_display():
    """DISPLAY/XAUTHORITY of the headless Luanti client running under Xvfb.

    This must never fall back to the desktop session: `import -window root`
    captures whatever display it is pointed at, and pointing it at :0 would
    photograph the user's screen instead of the game. So we require:
      * a real client binary, not the xvfb-run wrapper shell (which inherits
        the desktop DISPLAY) and not this script's own shell;
      * an XAUTHORITY under /tmp/xvfb-run.*, which only an Xvfb server has.
    Anything else is refused rather than guessed.
    """
    pids = subprocess.run(["pgrep", "-f", "luanti"],
                          capture_output=True, text=True).stdout.split()
    rejected = []
    for pid in pids:
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as handle:
                argv = handle.read().decode("utf-8", "replace").split("\0")
            with open(f"/proc/{pid}/environ", "rb") as handle:
                env = dict(
                    item.split("=", 1)
                    for item in handle.read().decode("utf-8", "replace").split("\0")
                    if "=" in item
                )
        except OSError:
            continue

        executable = os.path.basename(argv[0]) if argv and argv[0] else ""
        if executable != "luanti" or "--go" not in argv:
            continue

        display, xauth = env.get("DISPLAY"), env.get("XAUTHORITY")
        if display and xauth and xauth.startswith("/tmp/xvfb-run."):
            return display, xauth
        rejected.append(f"pid {pid}: DISPLAY={display} XAUTHORITY={xauth}")

    message = ["no headless Luanti client on an Xvfb display was found.",
               "Start one with scripts/run-testkit.sh."]
    if rejected:
        message.append("Refused (not an Xvfb display — capturing these would "
                       "screenshot the desktop):")
        message.extend("  " + item for item in rejected)
    raise SystemExit("\n".join(message))


def rc(chatcmd, params=""):
    payload = {
        "command": "runchat",
        "chatcmd": chatcmd,
        "params": params,
        "player": "pwbot",
        "nonce": str(time.time_ns()),
    }
    tmp = os.path.join(WORLD, "rc_cmd.json.tmp")
    with open(tmp, "w") as handle:
        json.dump(payload, handle)
    os.replace(tmp, os.path.join(WORLD, "rc_cmd.json"))


def find_game_window(display, xauth):
    """Window id of the Luanti window, so shots are the game and not the
    letterboxed Xvfb root."""
    env = dict(os.environ, DISPLAY=display, XAUTHORITY=xauth)
    listing = subprocess.run(["xwininfo", "-root", "-children"],
                             env=env, capture_output=True, text=True).stdout
    for line in listing.splitlines():
        if '"luanti"' in line.lower() or "luanti" in line.lower():
            match = re.search(r"(0x[0-9a-fA-F]+)", line.strip())
            if match and "root window" not in line:
                return match.group(1)
    return "root"


def grab(display, xauth, window, path):
    env = dict(os.environ, DISPLAY=display, XAUTHORITY=xauth)
    subprocess.run(["import", "-window", window, path], env=env, check=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--shotlist", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--limit", type=int, default=6,
                        help="number of settlements to photograph")
    parser.add_argument("--ids", default="",
                        help="comma-separated settlement ids to photograph, in order")
    parser.add_argument("--settle", type=float, default=6.0,
                        help="seconds to wait for the client to render after a move")
    args = parser.parse_args()

    if not shutil.which("import"):
        raise SystemExit("ImageMagick 'import' is required")

    display, xauth = find_client_display()
    window = find_game_window(display, xauth)
    print(f"client display={display} xauthority={xauth} window={window}")

    with open(args.shotlist) as handle:
        shotlist = json.load(handle)

    if args.ids:
        wanted = [item.strip() for item in args.ids.split(",") if item.strip()]
        by_id = {s["settlement_id"]: s for s in shotlist["settlements"]}
        missing = [item for item in wanted if item not in by_id]
        if missing:
            raise SystemExit("not in shot list: " + ", ".join(missing))
        settlements = [by_id[item] for item in wanted]
    else:
        settlements = shotlist["settlements"][: args.limit]
    os.makedirs(args.out, exist_ok=True)

    rc("pw_photo_setup")
    time.sleep(3)

    metadata = []
    for index, settlement in enumerate(settlements, start=1):
        print(f"[{index}/{len(settlements)}] {settlement['settlement_id']} "
              f"({settlement['archetype']}, {settlement['biome_family']})")
        for shot in settlement["shots"]:
            frm, target = shot["from"], shot["target"]
            rc("pw_photo_at", "{} {} {} {} {} {}".format(
                frm["x"], frm["y"], frm["z"], target["x"], target["y"], target["z"]))
            time.sleep(args.settle)
            # Re-issue: the first move often lands before the client has the
            # mapblocks, and pw_photo_setup's HUD flags can be reset by respawn.
            rc("pw_photo_setup")
            time.sleep(1.0)
            rc("pw_photo_at", "{} {} {} {} {} {}".format(
                frm["x"], frm["y"], frm["z"], target["x"], target["y"], target["z"]))
            time.sleep(2.0)

            filename = "{:02d}_{}_{}_{}.png".format(
                index, settlement["archetype"], settlement["biome_family"], shot["name"])
            path = os.path.join(args.out, filename)
            grab(display, xauth, window, path)
            print(f"    {shot['name']:9} -> {filename}")

            metadata.append({
                "filename": filename,
                "settlement_id": settlement["settlement_id"],
                "candidate_id": settlement["candidate_id"],
                "region_id": settlement["region_id"],
                "view": shot["name"],
                "coordinates": settlement["center"],
                "teleport_command": settlement["teleport_command"],
                "camera_position": frm,
                "camera_target": target,
                "biome_name": settlement["biome_name"],
                "biome_family": settlement["biome_family"],
                "archetype": settlement["archetype"],
                "size_class": settlement["size_class"],
                "palette": settlement["palette"],
                "lot_count": settlement["lot_count"],
                "structure_variants": settlement["structure_variants"],
                "road_graph_fingerprint": settlement["road_graph_fingerprint"],
                "exact_plan_fingerprint": settlement["exact_plan_fingerprint"],
                "structural_fingerprint": settlement["structural_fingerprint"],
                "status": settlement["status"],
            })

    meta_path = os.path.join(args.out, "metadata.json")
    with open(meta_path, "w") as handle:
        json.dump({
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "world_seed": shotlist.get("world_seed"),
            "screenshots": metadata,
        }, handle, indent=2)

    md_path = os.path.join(args.out, "metadata.md")
    with open(md_path, "w") as handle:
        handle.write("# Village screenshot metadata\n\n")
        handle.write(f"- world seed: `{shotlist.get('world_seed')}`\n")
        handle.write(f"- screenshots: {len(metadata)}\n\n")
        for entry in metadata:
            handle.write(f"## {entry['filename']}\n\n")
            for key in ["settlement_id", "candidate_id", "region_id", "view", "status",
                        "biome_name", "biome_family", "palette", "archetype",
                        "size_class", "lot_count"]:
                handle.write(f"- {key}: `{entry[key]}`\n")
            handle.write(f"- coordinates: `{entry['coordinates']}`\n")
            handle.write(f"- teleport command: `{entry['teleport_command']}`\n")
            handle.write(f"- camera position: `{entry['camera_position']}`\n")
            handle.write(f"- camera direction: looking at `{entry['camera_target']}`\n")
            handle.write(f"- structure variants: `{', '.join(entry['structure_variants'])}`\n")
            handle.write(f"- road graph fingerprint: `{entry['road_graph_fingerprint']}`\n")
            handle.write(f"- exact plan fingerprint: `{entry['exact_plan_fingerprint']}`\n")
            handle.write(f"- structural fingerprint: `{entry['structural_fingerprint']}`\n\n")

    print(f"\n{len(metadata)} screenshots -> {os.path.abspath(args.out)}")
    print(f"metadata -> {os.path.abspath(meta_path)}")
    print(f"metadata -> {os.path.abspath(md_path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
