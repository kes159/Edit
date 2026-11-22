"""Shared Korean change notes and build metadata formatting."""

import re
import subprocess


def korean_changes(message):
    lines = message.strip().splitlines()
    for index, line in enumerate(lines):
        if re.fullmatch(r"(?:#{1,6}\s+)?수정사항\s*[:：]?", line.strip()):
            notes = []
            for entry in lines[index + 1:]:
                entry = entry.strip()
                if re.match(r"(?:#{1,6}\s|(?:Co-authored-by|Signed-off-by|Reviewed-by):)", entry, re.I):
                    break
                if not entry or entry.lower() in ("[skip ci]", "[ci skip]"):
                    continue
                notes.append(re.sub(r"^[-*]\s+", "", entry))
            if notes and re.search(r"[가-힣]", " ".join(notes)):
                return notes
    subject = re.sub(r"\s*\[(?:skip ci|ci skip)\]", "", lines[0], flags=re.I).strip() if lines else ""
    return [subject] if re.search(r"[가-힣]", subject) else []


def markdown_text(value):
    return re.sub(r"([\\`*_{}\[\]()<>#+.!|])", r"\\\1", value)


def render_summary(commit, message, repository):
    link = commit[:7]
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        link = f"[{link}](https://github.com/{repository}/commit/{commit})"
    lines = ["", "### 최신 커밋 수정사항", "", f"빌드 기준 커밋: {link}", ""]
    notes = korean_changes(message)
    if notes:
        lines.extend(f"- {markdown_text(note)}" for note in notes)
    else:
        lines.append("이 커밋에는 한국어 수정사항이 기록되어 있지 않습니다.")
        subject = message.strip().splitlines()[0] if message.strip() else "(제목 없음)"
        lines.extend(["", f"> 원문 커밋 제목: {markdown_text(subject)}"])
    return "\n".join(lines) + "\n"



def read_commit(reference):
    commit = subprocess.check_output(
        ["git", "rev-parse", "--verify", "--end-of-options", f"{reference}^{{commit}}"], text=True
    ).strip()
    message = subprocess.check_output(["git", "show", "-s", "--format=%B", commit], text=True)
    return commit, message
