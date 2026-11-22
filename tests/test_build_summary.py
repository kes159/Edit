from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "write-build-summary.py"
sys.path.insert(0, str(SCRIPT.parent))
import build_notes as summary


class BuildSummaryTests(unittest.TestCase):
    def test_english_title_uses_korean_translation_in_body(self):
        message = "Fix scrolling [skip ci]\n\n수정사항:\n- 관성 스크롤 중에도 맨 위로 이동합니다.\n- 사이드바 버튼을 유지합니다.\n\nCo-authored-by: Example <example@example.invalid>"
        notes = summary.korean_changes(message)
        self.assertEqual(notes, ["관성 스크롤 중에도 맨 위로 이동합니다.", "사이드바 버튼을 유지합니다."])

    def test_korean_subject_is_supported(self):
        self.assertEqual(summary.korean_changes("스크롤 동작 수정 [skip ci]\n"), ["스크롤 동작 수정"])

    def test_missing_translation_does_not_invent_changes(self):
        result = summary.render_summary("a" * 40, "Unknown English commit", "example/source")
        self.assertIn("한국어 수정사항이 기록되어 있지 않습니다", result)
        self.assertIn("Unknown English commit", result)

    def test_commit_notes_are_literal_markdown_text(self):
        result = summary.render_summary("a" * 40, "Fix\n\n수정사항:\n- [링크](https://example.invalid)와 <태그> 확인", "example/source")
        self.assertIn(r"\[링크\]", result)
        self.assertIn(r"\<태그\>", result)

    def test_build_ref_and_existing_download_link_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)

            def commit(message):
                subprocess.run(
                    ["git", "-c", "user.name=Source Editor", "-c", "user.email=source-editor@example.invalid",
                     "commit", "--allow-empty", "-q", "-m", message], cwd=root, check=True
                )
                return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()

            built = commit("Fix first\n\n수정사항:\n- 빌드한 커밋의 수정사항")
            commit("Fix second\n\n수정사항:\n- 다른 커밋의 수정사항")
            output = root / "summary.md"
            download = "[Source_Editor.ipa](https://github.com/example/source/releases/download/build/Source_Editor.ipa)\n"
            output.write_text(download, encoding="utf-8")
            subprocess.run(
                [sys.executable, str(SCRIPT), "--commit", built, "--repository", "example/source", "--summary", str(output)],
                cwd=root, check=True
            )
            result = output.read_text(encoding="utf-8")
            self.assertTrue(result.startswith(download))
            self.assertIn("빌드한 커밋의 수정사항", result)
            self.assertNotIn("다른 커밋의 수정사항", result)
            self.assertIn(f"/commit/{built}", result)


if __name__ == "__main__":
    unittest.main()
