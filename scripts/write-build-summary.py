#!/usr/bin/env python3
"""Append the built commit's Korean change notes to the Actions job summary."""

import argparse
import os
from pathlib import Path
from build_notes import read_commit, render_summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA", "HEAD"))
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    args = parser.parse_args()
    commit, message = read_commit(args.commit)
    summary = render_summary(commit, message, args.repository)
    if args.summary:
        with Path(args.summary).open("a", encoding="utf-8") as output:
            output.write(summary)
    else:
        print(summary, end="")


if __name__ == "__main__":
    main()
