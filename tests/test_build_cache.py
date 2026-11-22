import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from build_cache import restore_inputs, save_inputs


class BuildCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.source = self.root / "Source/한글 file.swift"
        self.source.parent.mkdir()
        self.source.write_text("let value = 1\n")
        subprocess.run(["git", "add", "Source"], cwd=self.root, check=True)
        self.manifest = self.root / "build/DerivedData/source-input-mtimes.json"
        self.old = 1_700_000_000_123_456_789
        self.fresh = self.old + 10_000_000_000
        os.utime(self.source, ns=(self.old, self.old))

    def save_then_touch(self):
        self.assertEqual(save_inputs(self.root, self.manifest), 1)
        os.utime(self.source, ns=(self.fresh, self.fresh))

    def test_unchanged_input_regains_cached_timestamp_without_changing_content(self):
        self.save_then_touch()
        self.assertEqual(restore_inputs(self.root, self.manifest), 1)
        self.assertEqual(self.source.stat().st_mtime_ns, self.old)
        self.assertEqual(self.source.read_text(), "let value = 1\n")

    def test_same_size_content_edit_keeps_new_timestamp_for_recompilation(self):
        self.save_then_touch()
        self.source.write_text("let value = 2\n")
        os.utime(self.source, ns=(self.fresh, self.fresh))
        self.assertEqual(restore_inputs(self.root, self.manifest), 0)
        self.assertEqual(self.source.stat().st_mtime_ns, self.fresh)
        self.assertEqual(self.source.read_text(), "let value = 2\n")

    def test_deleted_and_untracked_inputs_are_not_restored_from_manifest(self):
        self.save_then_touch()
        saved = json.loads(self.manifest.read_text())
        untracked = self.root / "untracked.swift"
        untracked.write_text(self.source.read_text())
        os.utime(untracked, ns=(self.fresh, self.fresh))
        saved["files"]["untracked.swift"] = saved["files"]["Source/한글 file.swift"]
        self.manifest.write_text(json.dumps(saved))
        self.source.unlink()
        self.assertEqual(restore_inputs(self.root, self.manifest), 0)
        self.assertFalse(self.source.exists())
        self.assertEqual(untracked.stat().st_mtime_ns, self.fresh)

    def test_cold_or_invalid_manifest_falls_back_to_normal_build(self):
        self.assertEqual(restore_inputs(self.root, self.manifest), 0)
        self.manifest.parent.mkdir(parents=True)
        for text in ["not json", "[]", '{"version":2,"files":{}}', '{"version":1,"files":[]}']:
            with self.subTest(text=text):
                self.manifest.write_text(text)
                self.assertEqual(restore_inputs(self.root, self.manifest), 0)

    def test_invalid_timestamp_is_ignored_without_changing_the_source(self):
        self.save_then_touch()
        saved = json.loads(self.manifest.read_text())
        for mtime in [-1, "123", True, 10**100]:
            with self.subTest(mtime=mtime):
                saved["files"]["Source/한글 file.swift"]["mtime_ns"] = mtime
                self.manifest.write_text(json.dumps(saved))
                self.assertEqual(restore_inputs(self.root, self.manifest), 0)
                self.assertEqual(self.source.stat().st_mtime_ns, self.fresh)


if __name__ == "__main__":
    unittest.main()
