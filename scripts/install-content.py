#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile
import hashlib
from pathlib import Path
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
CONFIG = ROOT / "config" / "content.json"
LOCK = ROOT / "locks" / "content.lock.json"

DESTS = {
    "games": DATA / "games",
    "mods": DATA / "mods",
    "dev_mods": DATA / "mods",
    "texturepacks": DATA / "texturepacks",
}

MARKERS = {
    "games": ["game.conf"],
    "mods": ["mod.conf", "modpack.conf"],
    "dev_mods": ["mod.conf", "modpack.conf"],
    "texturepacks": ["texture_pack.conf"],
}

def setup_proxy(proxy_url: str | None):
    if proxy_url is None:
        proxy_url = os.environ.get("HTTP_PROXY") or os.environ.get("HTTPS_PROXY")
    if proxy_url:
        proxy_support = urllib.request.ProxyHandler({
            "http": proxy_url,
            "https": proxy_url,
        })
        opener = urllib.request.build_opener(proxy_support)
        urllib.request.install_opener(opener)

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def download(author: str, name: str, tmpdir: Path) -> Path:
    url = f"https://content.luanti.org/packages/{author}/{name}/download/"
    out = tmpdir / f"{author}__{name}.zip"
    print(f"Downloading {author}/{name}", flush=True)
    urllib.request.urlretrieve(url, out)
    return out

def find_content_root(extract_dir: Path, markers: list[str]) -> Path:
    candidates = []
    for path in extract_dir.rglob("*"):
        if path.is_dir():
            for marker in markers:
                if (path / marker).exists():
                    candidates.append(path)
                    break

    if not candidates:
        raise RuntimeError(f"No content root found in {extract_dir}")

    candidates.sort(key=lambda p: len(p.relative_to(extract_dir).parts))
    return candidates[0]

def install_package(section: str, item: dict, lock_items: list[dict]):
    author = item["author"]
    name = item["name"]
    target = item["target"]

    dest_base = DESTS[section]
    dest_base.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as td:
        tmpdir = Path(td)
        zip_path = download(author, name, tmpdir)
        digest = sha256_file(zip_path)

        extract_dir = tmpdir / "extract"
        extract_dir.mkdir()

        with zipfile.ZipFile(zip_path) as z:
            z.extractall(extract_dir)

        root = find_content_root(extract_dir, MARKERS[section])
        dest = dest_base / target

        if dest.exists():
            shutil.rmtree(dest)

        shutil.copytree(root, dest)

        lock_items.append({
            "section": section,
            "author": author,
            "name": name,
            "target": target,
            "installed_to": str(dest.relative_to(ROOT)),
            "downloaded_at": datetime.now(timezone.utc).isoformat(),
            "sha256": digest,
            "source": f"ContentDB:{author}/{name}"
        })

        print(f"Installed {author}/{name} -> {dest}")

def main():
    parser = argparse.ArgumentParser(description="Install Luanti content from ContentDB")
    parser.add_argument("--proxy", help="HTTP/HTTPS proxy (e.g. http://127.0.0.1:12334)")
    args = parser.parse_args()

    setup_proxy(args.proxy)

    with CONFIG.open("r", encoding="utf-8") as f:
        manifest = json.load(f)

    lock_items = []

    for section in ["games", "mods", "texturepacks"]:
        for item in manifest.get(section, []):
            install_package(section, item, lock_items)

    include_dev = os.environ.get("INCLUDE_DEV_MODS") == "1"
    if include_dev:
        for item in manifest.get("dev_mods", []):
            install_package("dev_mods", item, lock_items)

    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open("w", encoding="utf-8") as f:
        json.dump({
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "items": lock_items
        }, f, ensure_ascii=False, indent=2)

    print(f"Lock written to {LOCK}")

if __name__ == "__main__":
    main()
