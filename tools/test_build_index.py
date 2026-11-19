"""Tests of build_index.py. Run: python3 -m unittest discover -s tools -v"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_index  # noqa: E402

MIT = "MIT License\n\nCopyright (c) 2026 Someone\n"


def git(root, *args):
    out = subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
        cwd=root, check=True, capture_output=True, text=True)
    return out.stdout.strip()


class Repo:
    """A throwaway marketplace repository."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        git(self.root, "init", "-q")
        (self.root / ".gitignore").write_text("secrets.env\n")

    def app(self, name, version="1.0.0", lua_api=1, license="MIT", extra=None, meta=None):
        d = self.root / name
        d.mkdir(exist_ok=True)
        m = {"title": name.title(), "description": "About " + name, "version": version,
             "author": "Someone", "license": license, "lua_api": lua_api}
        if meta is not None:
            m = meta
        (d / "app.json").write_text(json.dumps(m, indent=2) + "\n")
        (d / "main.lua").write_text("print('hi')\n")
        (d / "LICENSE").write_text(MIT)
        (d / "README.md").write_text("# " + name + "\n")
        for path, data in (extra or {}).items():
            (d / path).parent.mkdir(exist_ok=True)
            (d / path).write_bytes(data if isinstance(data, bytes) else data.encode())
        return d

    def commit(self):
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "x", "--allow-empty")
        return git(self.root, "rev-parse", "HEAD")

    def build(self, previous=None):
        index, errors = build_index.build_index(self.root, git(self.root, "rev-parse", "HEAD"), previous)
        if errors:
            raise AssertionError(errors)
        return index

    def close(self):
        self.tmp.cleanup()


def sha(data):
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


class BuildIndexTest(unittest.TestCase):
    def setUp(self):
        self.r = Repo()

    def tearDown(self):
        self.r.close()

    def test_new_app_gets_current_commit(self):
        self.r.app("hello")
        c = self.r.commit()
        index = self.r.build()
        self.assertEqual(index["format"], 1)
        app = index["apps"]["hello"]
        self.assertEqual(app["title"], "Hello")
        self.assertEqual(app["license"], "MIT")
        self.assertEqual(len(app["versions"]), 1)
        v = app["versions"][0]
        self.assertEqual((v["version"], v["lua_api"], v["commit"]), ("1.0.0", 1, c))
        self.assertEqual([f["path"] for f in v["files"]], ["app.json", "main.lua"])
        self.assertEqual([f["path"] for f in v["other_files"]], ["LICENSE", "README.md"])
        main = v["files"][1]
        self.assertEqual(main["size"], len("print('hi')\n"))
        self.assertEqual(main["sha256"], sha("print('hi')\n"))

    def test_same_version_keeps_old_entry(self):
        d = self.r.app("hello")
        a = self.r.commit()
        first = self.r.build()
        (d / "README.md").write_text("# Hello, again\n")      # not a board file: no bump needed
        self.r.commit()
        second = self.r.build(first)
        v = second["apps"]["hello"]["versions"]
        self.assertEqual(len(v), 1)
        self.assertEqual(v[0]["commit"], a)
        self.assertEqual(v[0]["other_files"][1]["sha256"], sha("# hello\n"))

    def test_changed_board_files_need_a_bump(self):
        d = self.r.app("hello")
        self.r.app("other")
        self.r.commit()
        first = self.r.build()
        (d / "main.lua").write_text("print('changed')\n")
        self.r.commit()
        index, errors = build_index.build_index(self.r.root, git(self.r.root, "rev-parse", "HEAD"), first)
        self.assertEqual(errors, ["hello: its files changed since version 1.0.0 was published:"
                                  " bump the version in app.json"])
        self.assertNotIn("hello", index["apps"])

    def test_bump_replaces_entry_same_lua_api(self):
        self.r.app("hello")
        self.r.commit()
        first = self.r.build()
        self.r.app("hello", version="1.0.1")
        b = self.r.commit()
        v = self.r.build(first)["apps"]["hello"]["versions"]
        self.assertEqual([(e["version"], e["commit"]) for e in v], [("1.0.1", b)])

    def test_new_lua_api_keeps_older_api_entry(self):
        self.r.app("hello")
        a = self.r.commit()
        first = self.r.build()
        self.r.app("hello", version="2.0.0", lua_api=2)
        b = self.r.commit()
        v = self.r.build(first)["apps"]["hello"]["versions"]
        self.assertEqual([(e["version"], e["lua_api"], e["commit"]) for e in v],
                         [("2.0.0", 2, b), ("1.0.0", 1, a)])

    def test_versions_compare_as_numbers(self):
        self.r.app("hello", version="1.9.0")
        self.r.commit()
        first = self.r.build()
        self.r.app("hello", version="1.10.0")
        self.r.commit()
        v = self.r.build(first)["apps"]["hello"]["versions"]
        self.assertEqual([e["version"] for e in v], ["1.10.0"])

    def test_board_and_other_files(self):
        self.r.app("hello", extra={"Pic.JPG": b"\xff\xd8", "s.wav": b"RIFF", "logo.png": b"\x89PNG",
                                   "img/shot.png": b"\x89PNG", "secrets.env.example": "k=\n",
                                   "sim_device.json": "{}"})
        self.r.commit()
        v = self.r.build()["apps"]["hello"]["versions"][0]
        self.assertEqual([f["path"] for f in v["files"]], ["Pic.JPG", "app.json", "logo.png", "main.lua", "s.wav"])
        self.assertEqual([f["path"] for f in v["other_files"]],
                         ["LICENSE", "README.md", "secrets.env.example", "sim_device.json"])

    def test_needs_setup(self):
        self.r.app("plain")
        self.r.app("keys", extra={"secrets.env.example": "# where to get it\nkey=\nopt=default\n# more=x\n"})
        self.r.app("quoted", extra={"secrets.env.example": 'k = ""\n'})
        self.r.app("optional", extra={"secrets.env.example": "place=Helsinki\n# lat=60.1\n\n"})
        self.r.commit()
        apps = self.r.build()["apps"]
        self.assertEqual({n: a["needs_setup"] for n, a in apps.items()},
                         {"plain": False, "keys": True, "quoted": True, "optional": False})

    def test_bad_secrets_example(self):
        self.r.app("bad", extra={"secrets.env.example": "just text\n"})
        self.r.commit()
        _, errors = build_index.build_index(self.r.root, git(self.r.root, "rev-parse", "HEAD"), None)
        self.assertEqual(errors, ["bad: secrets.env.example line 1: expected NAME=value"])

    def test_board_lines(self):
        lines = build_index.board_lines
        self.assertEqual(lines("", 10), 0)
        self.assertEqual(lines("aaaa bbbb", 9), 1)                 # fits whole
        self.assertEqual(lines("aaaa bbbb", 8), 2)                 # breaks at the space
        self.assertEqual(lines("aaaa bbbbb cc", 10), 2)            # a space right after the line breaks there
        self.assertEqual(lines("abcdefghijkl", 5), 3)              # no space: mid-word
        self.assertEqual(lines("ääää ääää", 4), 2)                 # a character is one, whatever its bytes
        self.assertEqual(lines("WWWW iiii", 4), 2)                 # ... and whatever its looks (one font cell)
        self.assertEqual(lines("aaaa\nbbbb", 9), 1)                # a line break reads as a space

    def test_text_the_board_shows(self):
        fits = "x" * 47 + " " + "y" * 47 + " " + "z" * 48              # 3 lines of 48
        self.r.app("ok", meta={"title": "T" * 31, "description": fits, "version": "1.0.0", "author": "A" * 31,
                               "license": "MIT", "lua_api": 1})
        self.r.app("wordy", meta={"title": "Wordy", "description": fits + " more", "version": "1.0.0",
                                  "license": "MIT", "lua_api": 1})
        self.r.app("setup", extra={"secrets.env.example": "key=\n"},
                   meta={"title": "Setup", "description": "w" * 26 * 4 + " x", "version": "1.0.0",
                         "license": "MIT", "lua_api": 1})
        self.r.app("long", meta={"title": "Ö" * 16, "description": "d", "version": "1.0.0", "author": "a",
                                 "license": "L" * 24, "lua_api": 1})
        self.r.commit()
        _, errors = build_index.build_index(self.r.root, git(self.r.root, "rev-parse", "HEAD"), None)
        self.assertEqual(sorted(errors), [
            "long: license is 24 bytes, at most 23",
            "long: title is 32 bytes, at most 31",
            "setup: description takes 5 lines of 26 characters beside the QR code on its Marketplace page, "
            "the board shows 4",
            "wordy: description takes 4 lines of 48 characters in its options, the board shows 3",
        ])

    def test_files_the_board_takes(self):
        most = build_index.LIMITS
        long = "n" * (most["file_name"] - 4) + ".lua"                   # as long as a file name gets
        self.r.app("ok", extra={long: "x\n", "pic.png": b"p" * most["file_bytes"],
                                "img/a much longer name than the board takes.png": b"p",
                                "notes of any length, in any words.txt": "x\n"})
        self.r.app("names", extra={"n" + long: "x\n", "two words.lua": "x\n"})
        self.r.app("big", extra={"pic.png": b"p" * (most["file_bytes"] + 1)})
        self.r.app("many", extra={f"m{i}.lua": "x\n" for i in range(most["files"] - 1)})
        self.r.commit()
        index, errors = build_index.build_index(self.r.root, git(self.r.root, "rev-parse", "HEAD"), None)
        self.assertEqual(sorted(errors), [
            "big: pic.png is 262145 bytes, at most 262144",
            "many: 33 files for the board, at most 32",
            "names: " + "n" + long + " isn't a file name the board takes (1..31 characters, A-Z a-z 0-9 _ . -)",
            "names: two words.lua isn't a file name the board takes (1..31 characters, A-Z a-z 0-9 _ . -)",
        ])
        self.assertEqual(list(index["apps"]), ["ok"])

    def test_names_the_board_takes(self):
        ok = build_index.valid_name
        self.assertTrue(ok("a" * 23, 23) and ok("a.b-c_D9", 23))
        self.assertFalse(ok("a" * 24, 23) or ok("", 23) or ok(".a", 23) or ok("a b", 23) or ok("a\n", 23)
                         or ok("ä", 23) or ok("a/b", 23))

    def test_an_index_the_board_reads(self):
        self.r.app("hello")
        c = self.r.commit()
        out = self.r.root / "index.json"
        self.assertEqual(build_index.main(["--root", str(self.r.root), "--commit", c]), 0)
        size = out.stat().st_size
        whole = dict(build_index.LIMITS)
        try:
            build_index.LIMITS["index_bytes"] = size - 1
            out.unlink()
            self.assertEqual(build_index.main(["--root", str(self.r.root), "--commit", c]), 1)
            self.assertFalse(out.exists())
            build_index.LIMITS.update(index_bytes=size, apps=0)
            _, errors = build_index.build_index(self.r.root, c, None)
            self.assertEqual(errors, ["1 apps, boards read at most 0"])
        finally:
            build_index.LIMITS.update(whole)

    def test_untracked_files_ignored(self):
        d = self.r.app("hello")
        self.r.commit()
        (d / "secrets.env").write_text("key=real\n")
        (d / "x.lua").write_text("x\n")
        text = json.dumps(self.r.build())
        self.assertNotIn("secrets.env\"", text)
        self.assertNotIn("x.lua", text)

    def test_subfolders_ignored(self):
        d = self.r.app("hello")
        (d / "sub").mkdir()
        (d / "sub" / "deep.lua").write_text("x\n")
        self.r.commit()
        self.assertNotIn("deep.lua", json.dumps(self.r.build()))

    def test_errors(self):
        cases = [
            ("nolicense", dict(license="")),
            ("badver", dict(version="1.0")),
            ("beta", dict(version="2.0.0-beta.1")),
            ("build", dict(version="1.0.0+x")),
            ("badapi", dict(lua_api=0)),
        ]
        for name, kw in cases:
            self.r.app(name, **kw)
        self.r.app("nolicfile")
        os.remove(self.r.root / "nolicfile" / "LICENSE")
        self.r.app("nomain")
        os.remove(self.r.root / "nomain" / "main.lua")
        broken = self.r.app("broken")
        (broken / "app.json").write_text("{ not json")
        self.r.app("bad name")
        self.r.app("good")
        self.r.commit()
        index, errors = build_index.build_index(self.r.root, "c" * 40, None)
        text = "\n".join(errors)
        for name in ["nolicense", "badver", "beta", "build", "badapi", "nolicfile", "nomain", "broken",
                     "bad name"]:
            self.assertIn(name, text.lower(), name)
        self.assertNotIn("good", text)
        out = self.r.root / "index.json"
        self.assertEqual(build_index.main(["--root", str(self.r.root), "--commit", "c" * 40]), 1)
        self.assertFalse(out.exists())

    def test_case_duplicates(self):
        # Folders that differ only in case can't both exist on macOS or Windows,
        # so this is checked on the names alone.
        errors = build_index.case_duplicates(["Clock", "clock", "hello", "HELLO2"])
        self.assertEqual(len(errors), 1)
        self.assertIn("Clock", errors[0])
        self.assertIn("clock", errors[0])

    def test_removed_app_dropped(self):
        self.r.app("hello")
        self.r.app("paint")
        self.r.commit()
        first = self.r.build()
        git(self.r.root, "rm", "-r", "-q", "paint")
        self.r.commit()
        self.assertEqual(list(self.r.build(first)["apps"]), ["hello"])

    def test_output_stable(self):
        self.r.app("paint")
        self.r.app("hello")
        c = self.r.commit()
        out = self.r.root / "index.json"
        self.assertEqual(build_index.main(["--root", str(self.r.root), "--commit", c]), 0)
        once = out.read_bytes()
        self.assertEqual(build_index.main(["--root", str(self.r.root), "--commit", c]), 0)
        self.assertEqual(out.read_bytes(), once)
        self.assertEqual(list(json.loads(once)["apps"]), ["hello", "paint"])
        self.assertTrue(once.endswith(b"\n"))

    def test_main_uses_previous_index(self):
        d = self.r.app("hello")
        a = self.r.commit()
        out = self.r.root / "index.json"
        self.assertEqual(build_index.main(["--root", str(self.r.root), "--commit", a]), 0)
        (d / "README.md").write_text("# changed\n")
        b = self.r.commit()
        self.assertEqual(build_index.main(["--root", str(self.r.root), "--commit", b]), 0)
        self.assertEqual(json.loads(out.read_text())["apps"]["hello"]["versions"][0]["commit"], a)

    def test_previous_from_another_file(self):
        d = self.r.app("hello")
        a = self.r.commit()
        self.assertEqual(build_index.main(["--root", str(self.r.root), "--commit", a]), 0)
        git(self.r.root, "add", "index.json")
        (d / "main.lua").write_text("print('changed')\n")
        b = self.r.commit()
        other = str(self.r.root / "elsewhere.json")
        args = ["--root", str(self.r.root), "--commit", b, "--out", other]
        self.assertEqual(build_index.main(args), 0)                                    # nothing to compare with
        self.assertEqual(build_index.main(args + ["--previous", str(self.r.root / "index.json")]), 1)


if __name__ == "__main__":
    unittest.main()
