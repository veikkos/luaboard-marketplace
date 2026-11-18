#!/usr/bin/env python3
"""Build index.json: every app in this repository and the versions boards
can install.

    python3 tools/build_index.py [--root .] [--commit SHA] [--out index.json]

Each app is a top-level folder. For each app the index keeps, per lua_api
value, the newest version: its commit (boards download its files from that
commit) and its files with size and sha256. A version already in the index
keeps its entry, even if its files changed since: bump the version to
publish a change. The previous index is read from --out. Only tracked files
count, so secrets.env never gets in. Standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

FORMAT = 1
NOT_APPS = {"tools"}
BOARD_EXTS = (".jpg", ".jpeg", ".png", ".wav")
NAME = re.compile(r"^[A-Za-z0-9_.-]{1,23}$")
VERSION = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")


def is_board_file(name: str) -> bool:
    """Whether a file goes to the board (the same rule as the luaboard CLI)."""
    return name == "app.json" or name.endswith(".lua") or name.lower().endswith(BOARD_EXTS)


def parse_version(s) -> tuple | None:
    m = VERSION.match(s) if isinstance(s, str) else None
    return tuple(int(x) for x in m.groups()) if m else None


def git_files(root: Path) -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True).stdout
    return sorted(p for p in out.decode().split("\0") if p)


def tracked_files(root: Path, app: str) -> list[str]:
    """The app folder's tracked files at its top level, sorted."""
    prefix = app + "/"
    return sorted(p[len(prefix):] for p in git_files(root) if p.startswith(prefix) and "/" not in p[len(prefix):])


def file_entry(path: Path, name: str) -> dict:
    data = path.read_bytes()
    return {"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def read_app(root: Path, app: str) -> tuple[dict, list[str]]:
    """The app's info from its folder, and what's wrong with it."""
    errors = []
    err = errors.append
    if not NAME.match(app) or app.startswith("."):
        err(f"{app}: not a valid app name (1..23 characters, A-Z a-z 0-9 _ . -)")
    names = tracked_files(root, app)
    try:
        meta = json.loads((root / app / "app.json").read_text(encoding="utf-8"))
        if not isinstance(meta, dict):
            raise ValueError("not a JSON object")
    except (OSError, ValueError) as e:
        return {}, errors + [f"{app}: app.json missing or broken ({e})"]
    version = meta.get("version")
    if parse_version(version) is None:
        err(f"{app}: version {version!r} isn't MAJOR.MINOR.PATCH (no pre-releases)")
    lua_api = meta.get("lua_api", 1)
    if not isinstance(lua_api, int) or isinstance(lua_api, bool) or lua_api < 1:
        err(f"{app}: lua_api {lua_api!r} isn't a whole number >= 1")
    license_ = meta.get("license")
    if not isinstance(license_, str) or not license_.strip():
        err(f"{app}: no license in app.json")
    if "LICENSE" not in names:
        err(f"{app}: no LICENSE file")
    if "main.lua" not in names:
        err(f"{app}: no main.lua")
    info = {
        "title": str(meta.get("title", "")),
        "description": str(meta.get("description", "")),
        "author": str(meta.get("author", "")),
        "license": license_ if isinstance(license_, str) else "",
        "version": version,
        "lua_api": lua_api,
        "files": [file_entry(root / app / n, n) for n in names if is_board_file(n)],
        "other_files": [file_entry(root / app / n, n) for n in names if not is_board_file(n)],
    }
    return info, errors


def app_names(root: Path) -> list[str]:
    tops = {p.split("/", 1)[0] for p in git_files(root) if "/" in p}
    return sorted(n for n in tops if not n.startswith(".") and n not in NOT_APPS)


def case_duplicates(names: list[str]) -> list[str]:
    """An error for each name that equals an earlier one ignoring case."""
    seen, errors = {}, []
    for name in names:
        other = seen.setdefault(name.lower(), name)
        if other != name:
            errors.append(f"{other} and {name}: two apps with the same name (ignoring case)")
    return errors


def build_index(root: Path, commit: str, previous: dict | None) -> tuple[dict, list[str]]:
    """The new index, and every error found (an index with errors isn't written)."""
    root = Path(root)
    prev_apps = (previous or {}).get("apps", {})
    names = app_names(root)
    apps, errors = {}, case_duplicates(names)
    for name in names:
        info, errs = read_app(root, name)
        errors += errs
        if errs:
            continue
        versions = list(prev_apps.get(name, {}).get("versions", []))
        if not any(v.get("version") == info["version"] for v in versions):
            versions.append({"version": info["version"], "lua_api": info["lua_api"], "commit": commit,
                             "files": info["files"], "other_files": info["other_files"]})
        newest = {}
        for v in versions:
            best = newest.get(v["lua_api"])
            if best is None or parse_version(v["version"]) > parse_version(best["version"]):
                newest[v["lua_api"]] = v
        apps[name] = {
            "title": info["title"], "description": info["description"], "author": info["author"],
            "license": info["license"],
            "versions": sorted(newest.values(), key=lambda v: parse_version(v["version"]), reverse=True),
        }
    return {"format": FORMAT, "apps": apps}, errors


def main(argv) -> int:
    ap = argparse.ArgumentParser(description="Build index.json for luaboard boards.")
    ap.add_argument("--root", default=".")
    ap.add_argument("--commit")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    root = Path(a.root)
    out = Path(a.out) if a.out else root / "index.json"
    commit = a.commit or subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, check=True,
                                        capture_output=True, text=True).stdout.strip()
    previous = json.loads(out.read_text(encoding="utf-8")) if out.exists() else None
    index, errors = build_index(root, commit, previous)
    for e in errors:
        print("error: " + e, file=sys.stderr)
    if errors:
        return 1
    text = json.dumps(index, indent=1, ensure_ascii=False) + "\n"
    if not out.exists() or out.read_text(encoding="utf-8") != text:
        out.write_text(text, encoding="utf-8")
        print(f"wrote {out}: {len(index['apps'])} apps")
    else:
        print(f"{out} unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
