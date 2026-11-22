#!/usr/bin/env python3
"""Keep unchanged source mtimes compatible with Xcode's incremental build cache."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def tracked_files(root):
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root)
    for name in os.fsdecode(paths).split("\0"):
        if not name:
            continue
        path = root / name
        if not path.is_symlink() and path.is_file():
            yield name, path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_inputs(root, manifest):
    files = {
        name: {"sha256": digest(path), "mtime_ns": path.stat().st_mtime_ns}
        for name, path in tracked_files(root)
    }
    manifest.parent.mkdir(parents=True, exist_ok=True)
    temporary = manifest.with_suffix(".tmp")
    temporary.write_text(json.dumps({"version": 1, "files": files}), encoding="utf-8")
    temporary.replace(manifest)
    return len(files)


def restore_inputs(root, manifest):
    try:
        saved = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0  # A cold or unreadable cache still permits a normal full build.
    if not isinstance(saved, dict) or saved.get("version") != 1 or not isinstance(saved.get("files"), dict):
        return 0
    restored = 0
    # Iterate this checkout's tracked files, never paths supplied by the cache.
    for name, path in tracked_files(root):
        record = saved["files"].get(name)
        if not isinstance(record, dict):
            continue
        mtime = record.get("mtime_ns")
        if type(mtime) is not int or mtime < 0 or record.get("sha256") != digest(path):
            continue
        try:
            os.utime(path, ns=(path.stat().st_atime_ns, mtime))
        except (OSError, OverflowError):
            continue
        restored += 1
    return restored


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["restore", "save"])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = root / "build/DerivedData/source-input-mtimes.json"
    if args.operation == "save":
        count = save_inputs(root, manifest)
        print(f"Recorded {count} build input timestamps.")
    else:
        count = restore_inputs(root, manifest)
        print(f"Restored {count} unchanged build input timestamps; changed files keep their checkout timestamps.")


if __name__ == "__main__":
    main()
