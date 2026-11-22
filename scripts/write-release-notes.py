#!/usr/bin/env python3
"""Generate Source Editor release notes, title and checksum from the built IPA."""

import argparse
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path

from build_notes import read_commit
from release_notes import ipa_metadata, release_title, render_release_notes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--title-output", required=True, type=Path)
    parser.add_argument("--checksum-output", required=True, type=Path)
    parser.add_argument("--xcode-info", required=True, type=Path)
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA", "HEAD"))
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--branch", default=os.environ.get("GITHUB_REF_NAME", ""))
    parser.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", "0"))
    parser.add_argument("--run-number", default=os.environ.get("GITHUB_RUN_NUMBER", "0"))
    parser.add_argument("--attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
    args = parser.parse_args()
    commit, message = read_commit(args.commit)
    metadata = ipa_metadata(args.ipa)
    built_at = datetime.now(timezone(timedelta(hours=9))).strftime("%Y-%m-%d %H:%M:%S KST")
    xcode = " · ".join(line.strip() for line in args.xcode_info.read_text(encoding="utf-8").splitlines() if line.strip())
    notes = render_release_notes(metadata, commit, message, args.repository, args.tag, args.branch,
                                 args.run_id, args.run_number, args.attempt, built_at, xcode)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(notes, encoding="utf-8")
    args.title_output.parent.mkdir(parents=True, exist_ok=True)
    args.title_output.write_text(release_title(metadata, args.run_number, args.attempt) + "\n", encoding="utf-8")
    args.checksum_output.parent.mkdir(parents=True, exist_ok=True)
    args.checksum_output.write_text(f"{metadata['sha256']}  {metadata['filename']}\n", encoding="utf-8")


if __name__ == "__main__":
    main()
