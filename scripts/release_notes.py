"""Read built IPA metadata and format Source Editor release notes."""

import hashlib
from pathlib import Path
import plistlib
import re
from urllib.parse import quote
import zipfile

from build_notes import markdown_text, render_summary


def ipa_metadata(path):
    path = Path(path)
    with zipfile.ZipFile(path) as archive:
        candidates = [name for name in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(candidates) != 1:
            raise ValueError("IPA에는 최상위 앱 Info.plist가 하나 있어야 합니다.")
        if archive.getinfo(candidates[0]).file_size > 8 * 1024 * 1024:
            raise ValueError("앱 Info.plist가 너무 큽니다.")
        info = plistlib.loads(archive.read(candidates[0]))

    def required(key):
        value = " ".join(str(info.get(key, "")).split())
        if not value or "$(" in value:
            raise ValueError(f"빌드한 IPA의 {key} 값이 없거나 확정되지 않았습니다.")
        return value

    digest = hashlib.sha256()
    with path.open("rb") as ipa:
        for chunk in iter(lambda: ipa.read(1024 * 1024), b""):
            digest.update(chunk)
    families = info.get("UIDeviceFamily", [])
    devices = [name for number, name in [(1, "iPhone"), (2, "iPad")] if number in families]
    return {
        "version": required("CFBundleShortVersionString"),
        "build": required("CFBundleVersion"),
        "bundle_id": required("CFBundleIdentifier"),
        "minimum_os": required("MinimumOSVersion"),
        "devices": " · ".join(devices) or "IPA의 지원 기기 설정 참고",
        "size": path.stat().st_size,
        "sha256": digest.hexdigest(),
        "filename": path.name,
    }


def release_title(metadata, run_number, attempt):
    return f"Source Editor v{metadata['version']} (빌드 {metadata['build']}) · #{run_number}.{attempt}"


def render_release_notes(metadata, commit, message, repository, tag, branch, run_id, run_number, attempt, built_at, xcode):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("GitHub 저장소는 소유자/저장소 형식이어야 합니다.")
    if not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", commit):
        raise ValueError("빌드 커밋 SHA가 올바르지 않습니다.")
    if not tag.strip():
        raise ValueError("릴리즈 태그가 비어 있습니다.")
    if not str(run_id).isdigit() or not str(run_number).isdigit() or not str(attempt).isdigit():
        raise ValueError("워크플로 실행 번호가 올바르지 않습니다.")
    base = f"https://github.com/{repository}"
    asset = f"{base}/releases/download/{quote(tag, safe='')}/{quote(metadata['filename'], safe='')}"
    changes = render_summary(commit, message, repository).replace("### 최신 커밋 수정사항", "## 수정사항", 1).strip()
    size = f"{metadata['size'] / (1024 * 1024):.2f} MiB ({metadata['size']:,} 바이트)"
    lines = [
        f"# Source Editor v{markdown_text(metadata['version'])}", "",
        "iPhone·iPad에서 SideStore 소스 JSON을 만들고 편집하는 앱입니다.", "",
        "## 다운로드", "",
        f"[📥 {markdown_text(metadata['filename'])} 다운로드]({asset})", "",
        f"파일 크기: {size} · 서명되지 않은 IPA", "", changes, "",
        "## 앱·빌드 정보", "",
        "| 항목 | 내용 |", "| --- | --- |",
        f"| 앱 버전 | {markdown_text(metadata['version'])} |",
        f"| 앱 빌드 번호 | {markdown_text(metadata['build'])} |",
        f"| 최소 iOS/iPadOS | {markdown_text(metadata['minimum_os'])} 이상 |",
        f"| 지원 기기 | {markdown_text(metadata['devices'])} |",
        f"| 번들 ID(BundleIdentifier) | {markdown_text(metadata['bundle_id'])} |",
        f"| 기준 브랜치 | {markdown_text(branch)} |",
        f"| 워크플로 실행 | [#{run_number} · 시도 {attempt}]({base}/actions/runs/{run_id}) |",
        f"| 생성 시각 | {markdown_text(built_at)} |",
        f"| Xcode | {markdown_text(xcode)} |", "",
    ]
    if branch == "public":
        lines.extend(["공유용 public 빌드입니다. 다운로드 URL은 입력한 그대로 사용하고, 소스 웹사이트는 선택 입력합니다.", ""])
    elif branch == "main":
        lines.extend(["개인용 main 빌드입니다. 일반 공유용 빌드가 필요하면 public 브랜치를 선택하세요.", ""])
    lines.extend([
        "## 주요 기능", "",
        "- 소스 정보·앱·버전·뉴스·스크린샷·권한 편집",
        "- 사진·파일 이미지 선택, 위치·크기 조정 및 이미지 업로드",
        "- 파일과 공개·비공개 GitHub 저장소에서 JSON 불러오기",
        "- JSON 검사·미리보기·부분 복사·전체 복사 및 파일 내보내기",
        "- 앱에서 GitHub 저장소에 JSON 업로드", "",
        "## 설치 방법", "",
        "1. 위의 IPA 다운로드 링크를 눌러 파일을 저장합니다.",
        "2. Feather에서 본인 인증서로 서명하거나, SideStore 등 사용 중인 설치 도구의 서명 절차에 따라 설치합니다.",
        "3. Source Editor를 열고 새 소스를 작성하거나 기존 JSON을 불러옵니다.", "",
        "## 사용 가이드", "",
        f"- [이 빌드의 사용 가이드]({base}/blob/{commit}/USER_GUIDE.md)",
        f"- [프로젝트 소개]({base}/blob/{commit}/README.md)", "",
        "## SHA-256", "",
        "```text", f"{metadata['sha256']}  {metadata['filename']}", "```", "",
        f"[SHA-256 확인 파일 다운로드]({asset}.sha256)", "",
    ])
    return "\n".join(lines)
