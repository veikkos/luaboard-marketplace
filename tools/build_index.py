#!/usr/bin/env python3
"""Build index.json: every app in this repository and the versions boards
can install.

    python3 tools/build_index.py [--root .] [--commit SHA] [--out index.json] [--previous index.json]

Each app is a top-level folder. For each app the index keeps, per lua_api
value, the newest version: its commit (boards download its files from that
commit) and its files with size and sha256. needs_setup says whether the
app's secrets.env.example has a key left empty: one users must set (a
default value, or a key commented out, is optional). A version already in the index
keeps its entry, so a change to an app's board files without a new version
is an error: boards would never get it. The previous index is read from
--previous (default: --out). Only tracked files
count, so secrets.env never gets in. Standard library only.

What a board takes is in board.json, next to this file: an app or an index
past a limit there is an error, since boards would leave the app out, or
the whole index, without a word.
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
NAME = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*")
VERSION = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")

# What a board takes. asset_types: the files that go to it besides .lua
# files and app.json, as the luaboard CLI sends them. limits: the most its
# firmware reads, of an index (apps, index_bytes), of an app (the length of
# its name, its files and each one's name and size) and of app.json's text
# in UTF-8 bytes, and the room its screens give a description: lines of
# characters in the app's options, and beside the QR code on the
# Marketplace page of an app that needs setup. luaboard's tests hold these
# to its firmware (app/test/test_apps_index.c) and CLI: none may be more
# than a firmware in use reads.
BOARD = json.loads(Path(__file__).with_name("board.json").read_text(encoding="utf-8"))
LIMITS = BOARD["limits"]
BOARD_EXTS = tuple("." + t for t in BOARD["asset_types"])


def valid_name(name: str, most: int) -> bool:
    """Whether the board takes this as an app's or a file's name."""
    return len(name) <= most and NAME.fullmatch(name) is not None


def is_board_file(name: str) -> bool:
    """Whether a file goes to the board (the same rule as the luaboard CLI)."""
    return name == "app.json" or name.endswith(".lua") or name.lower().endswith(BOARD_EXTS)


def required_secrets(text: str, app: str, err) -> list[str]:
    """The keys of a secrets.env.example left empty: the ones users must set."""
    keys = []
    for i, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            err(f"{app}: secrets.env.example line {i}: expected NAME=value")
            continue
        name, value = (s.strip() for s in line.split("=", 1))
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if not value:
            keys.append(name)
    return keys


def board_lines(text: str, cols: int) -> int:
    """The lines the board wraps text into at `cols` characters a line, as
    its menu does (text_wrap_cols): each line breaks at the last space
    within it, or mid-word when there is none. Control characters count as
    spaces, as the board reads them; every character is one."""
    s = re.sub(r"[\x00-\x1f]", " ", text)
    lines = 0
    while s:
        lines += 1
        if len(s) <= cols:
            break
        b = cols
        while b > 0 and s[b] != " ":
            b -= 1
        s = s[b if b > 0 else cols:].lstrip(" ")
    return lines


def check_text(meta: dict, app: str, setup: bool, err) -> None:
    """app.json's text within what the board keeps and shows."""
    for key in ("title", "description", "author", "license"):
        n, most = len(str(meta.get(key, "")).encode("utf-8")), LIMITS[key + "_bytes"]
        if n > most:
            err(f"{app}: {key} is {n} bytes, at most {most}")
    desc = str(meta.get("description", ""))
    rooms = [("description", "in its options")]
    rooms += [("description_qr", "beside the QR code on its Marketplace page")] * setup
    for room, where in rooms:
        lines, cols = LIMITS[room + "_lines"], LIMITS[room + "_cols"]
        n = board_lines(desc, cols)
        if n > lines:
            err(f"{app}: description takes {n} lines of {cols} characters {where}, the board shows {lines}")


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


def check_files(files: list[dict], app: str, err) -> None:
    """The app's board files within what the board installs."""
    if len(files) > LIMITS["files"]:
        err(f"{app}: {len(files)} files for the board, at most {LIMITS['files']}")
    for f in files:
        if not valid_name(f["path"], LIMITS["file_name"]):
            err(f"{app}: {f['path']} isn't a file name the board takes"
                f" (1..{LIMITS['file_name']} characters, A-Z a-z 0-9 _ . -)")
        if f["size"] > LIMITS["file_bytes"]:
            err(f"{app}: {f['path']} is {f['size']} bytes, at most {LIMITS['file_bytes']}")


def file_entry(path: Path, name: str) -> dict:
    data = path.read_bytes()
    return {"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def read_app(root: Path, app: str) -> tuple[dict, list[str]]:
    """The app's info from its folder, and what's wrong with it."""
    errors = []
    err = errors.append
    if not valid_name(app, LIMITS["app_name"]):
        err(f"{app}: not a valid app name (1..{LIMITS['app_name']} characters, A-Z a-z 0-9 _ . -)")
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
    setup = "secrets.env.example" in names and required_secrets(
        (root / app / "secrets.env.example").read_text(encoding="utf-8"), app, err)
    check_text(meta, app, bool(setup), err)
    files = [file_entry(root / app / n, n) for n in names if is_board_file(n)]
    check_files(files, app, err)
    info = {
        "title": str(meta.get("title", "")),
        "description": str(meta.get("description", "")),
        "author": str(meta.get("author", "")),
        "license": license_ if isinstance(license_, str) else "",
        "version": version,
        "lua_api": lua_api,
        "needs_setup": bool(setup),
        "files": files,
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
    if len(names) > LIMITS["apps"]:
        errors.append(f"{len(names)} apps, boards read at most {LIMITS['apps']}")
    for name in names:
        info, errs = read_app(root, name)
        errors += errs
        if errs:
            continue
        versions = list(prev_apps.get(name, {}).get("versions", []))
        published = next((v for v in versions if v.get("version") == info["version"]), None)
        if published is not None:
            def board(files):
                return sorted((f.get("path"), f.get("sha256")) for f in files)
            if board(published.get("files", [])) != board(info["files"]):
                errors.append(f"{name}: its files changed since version {info['version']} was published:"
                              " bump the version in app.json")
                continue
        else:
            versions.append({"version": info["version"], "lua_api": info["lua_api"], "commit": commit,
                             "files": info["files"], "other_files": info["other_files"]})
        newest = {}
        for v in versions:
            best = newest.get(v["lua_api"])
            if best is None or parse_version(v["version"]) > parse_version(best["version"]):
                newest[v["lua_api"]] = v
        apps[name] = {
            "title": info["title"], "description": info["description"], "author": info["author"],
            "license": info["license"], "needs_setup": info["needs_setup"],
            "versions": sorted(newest.values(), key=lambda v: parse_version(v["version"]), reverse=True),
        }
    return {"format": FORMAT, "apps": apps}, errors


def main(argv) -> int:
    ap = argparse.ArgumentParser(description="Build index.json for luaboard boards.")
    ap.add_argument("--root", default=".")
    ap.add_argument("--commit")
    ap.add_argument("--out")
    ap.add_argument("--previous")
    a = ap.parse_args(argv)
    root = Path(a.root)
    out = Path(a.out) if a.out else root / "index.json"
    prev = Path(a.previous) if a.previous else out
    commit = a.commit or subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, check=True,
                                        capture_output=True, text=True).stdout.strip()
    previous = json.loads(prev.read_text(encoding="utf-8")) if prev.exists() else None
    index, errors = build_index(root, commit, previous)
    text = json.dumps(index, indent=1, ensure_ascii=False) + "\n"
    size = len(text.encode("utf-8"))
    if size > LIMITS["index_bytes"]:
        errors.append(f"the index is {size} bytes, boards read at most {LIMITS['index_bytes']}")
    for e in errors:
        print("error: " + e, file=sys.stderr)
    if errors:
        return 1
    if not out.exists() or out.read_text(encoding="utf-8") != text:
        out.write_text(text, encoding="utf-8")
        print(f"wrote {out}: {len(index['apps'])} apps, {size} of {LIMITS['index_bytes']} bytes")
    else:
        print(f"{out} unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
