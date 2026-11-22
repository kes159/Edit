import hashlib
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from release_notes import ipa_metadata, release_title, render_release_notes


INFO = {
    "CFBundleShortVersionString": "9.8",
    "CFBundleVersion": "7",
    "CFBundleIdentifier": "app.sourceeditor",
    "MinimumOSVersion": "17.0",
    "UIDeviceFamily": [1, 2],
}


def fixture_ipa(path, info=None, fmt=plistlib.FMT_BINARY):
    with zipfile.ZipFile(path, "w") as archive:
        # Extension metadata must not be mistaken for the main app's metadata.
        archive.writestr("Payload/Source.app/PlugIns/Widget.appex/Info.plist", plistlib.dumps({"CFBundleShortVersionString": "999"}))
        archive.writestr("Payload/Source.app/Info.plist", plistlib.dumps(INFO if info is None else info, fmt=fmt))
        archive.writestr("Payload/Source.app/Source", b"fixture binary")


class ReleaseNotesTests(unittest.TestCase):
    def test_reads_actual_xml_and_binary_ipa_metadata_and_hash(self):
        for fmt in [plistlib.FMT_XML, plistlib.FMT_BINARY]:
            with self.subTest(fmt=fmt), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "Source_Editor.ipa"
                fixture_ipa(path, fmt=fmt)
                metadata = ipa_metadata(path)
                self.assertEqual(metadata["version"], "9.8")
                self.assertEqual(metadata["build"], "7")
                self.assertEqual(metadata["minimum_os"], "17.0")
                self.assertEqual(metadata["devices"], "iPhone · iPad")
                self.assertEqual(metadata["size"], len(path.read_bytes()))
                self.assertEqual(metadata["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())

    def test_rejects_missing_or_ambiguous_main_app(self):
        for apps in [[], ["One", "Two"]]:
            with self.subTest(apps=apps), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "Source_Editor.ipa"
                with zipfile.ZipFile(path, "w") as archive:
                    for app in apps:
                        archive.writestr(f"Payload/{app}.app/Info.plist", plistlib.dumps(INFO))
                with self.assertRaises(ValueError):
                    ipa_metadata(path)

    def test_rejects_unresolved_or_missing_build_values(self):
        cases = [dict(INFO, CFBundleShortVersionString="$(MARKETING_VERSION)"),
                 {key: value for key, value in INFO.items() if key != "MinimumOSVersion"}]
        for info in cases:
            with self.subTest(info=info), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "Source_Editor.ipa"
                fixture_ipa(path, info=info)
                with self.assertRaises(ValueError):
                    ipa_metadata(path)

    def test_release_has_changes_download_guide_install_and_build_info(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Source_Editor.ipa"
            fixture_ipa(path)
            metadata = ipa_metadata(path)
            notes = render_release_notes(metadata, "a" * 40, "Fix\n\n수정사항:\n- 코드 스크롤 개선",
                                         "example/source", "build-123-2", "public", "123", "12", "2",
                                         "2026-11-22 16:00:00 KST", "Xcode 26.6")
            for title in ["다운로드", "수정사항", "앱·빌드 정보", "주요 기능", "설치 방법", "사용 가이드", "SHA-256"]:
                self.assertIn(f"## {title}", notes)
            self.assertIn("코드 스크롤 개선", notes)
            self.assertIn("/releases/download/build-123-2/Source_Editor.ipa)", notes)
            self.assertIn("/releases/download/build-123-2/Source_Editor.ipa.sha256)", notes)
            self.assertIn(f"/blob/{'a' * 40}/USER_GUIDE.md", notes)
            self.assertIn("/actions/runs/123", notes)
            self.assertIn(metadata["sha256"], notes)
            self.assertIn("다운로드 URL은 입력한 그대로", notes)
            self.assertIn("서명되지 않은 IPA", notes)
            self.assertNotIn("개인용 main 빌드", notes)

    def test_main_and_other_branch_descriptions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Source_Editor.ipa"
            fixture_ipa(path)
            metadata = ipa_metadata(path)
            for branch, personal in [("main", True), ("feature/release-notes", False)]:
                notes = render_release_notes(metadata, "a" * 40, "한국어 수정", "example/source", "build-123-1",
                                             branch, "123", "12", "1", "KST", "Xcode")
                self.assertEqual("개인용 main 빌드" in notes, personal)

    def test_invalid_repository_commit_and_tag_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Source_Editor.ipa"
            fixture_ipa(path)
            metadata = ipa_metadata(path)
            for repo, sha, tag in [("not a repo", "a" * 40, "build"), ("example/source", "a" * 41, "build"),
                                  ("example/source", "a" * 40, "")]:
                with self.subTest(repo=repo, sha=sha, tag=tag), self.assertRaises(ValueError):
                    render_release_notes(metadata, sha, "수정", repo, tag, "main", "123", "12", "1", "KST", "Xcode")

    def test_cli_creates_matching_title_notes_and_checksum_for_built_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            for message in ["Fix built\n\n수정사항:\n- 빌드한 커밋의 한국어 내용", "Fix newer\n\n수정사항:\n- 더 나중 커밋의 내용"]:
                subprocess.run(["git", "-c", "user.name=Source Editor", "-c", "user.email=source-editor@example.invalid",
                                "commit", "--allow-empty", "-q", "-m", message], cwd=root, check=True)
                if "Fix built" in message:
                    built = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            ipa = root / "Source_Editor.ipa"
            fixture_ipa(ipa)
            xcode = root / "xcode.txt"
            xcode.write_text("Xcode 26.6\nBuild version Example\n", encoding="utf-8")
            notes, title, checksum = [root / filename for filename in ["notes.md", "title.txt", "Source_Editor.ipa.sha256"]]
            subprocess.run([
                sys.executable, str(SCRIPTS / "write-release-notes.py"), "--ipa", str(ipa), "--tag", "build-123-2",
                "--output", str(notes), "--title-output", str(title), "--checksum-output", str(checksum),
                "--xcode-info", str(xcode), "--commit", built, "--repository", "example/source", "--branch", "public",
                "--run-id", "123", "--run-number", "12", "--attempt", "2"
            ], cwd=root, check=True)
            self.assertEqual(title.read_text(encoding="utf-8"), "Source Editor v9.8 (빌드 7) · #12.2\n")
            result = notes.read_text(encoding="utf-8")
            self.assertIn("빌드한 커밋의 한국어 내용", result)
            self.assertNotIn("더 나중 커밋의 내용", result)
            self.assertIn("KST", result)
            self.assertIn(f"/commit/{built}", result)
            self.assertEqual(checksum.read_text(encoding="utf-8"), f"{hashlib.sha256(ipa.read_bytes()).hexdigest()}  Source_Editor.ipa\n")
            self.assertEqual(release_title(ipa_metadata(ipa), "12", "2"), title.read_text(encoding="utf-8").strip())


if __name__ == "__main__":
    unittest.main()
