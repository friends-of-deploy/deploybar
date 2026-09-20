#!/usr/bin/env python3
"""Exercise the exact CLI used by the release workflow."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("release-notes.py")


class ReleaseNotesTests(unittest.TestCase):
    def extract(self, text, version="1.2.0"):
        with tempfile.TemporaryDirectory() as directory:
            changelog = Path(directory) / "CHANGELOG.md"
            changelog.write_text(text, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), version, str(changelog)],
                capture_output=True, text=True,
            )

    def test_extracts_only_requested_release_and_preserves_markdown(self):
        result = self.extract(
            "# Changelog\n\n## [1.3.0] - 2026-10-01\nFuture\n\n"
            "## [1.2.0] - 2026-09-20\n\nHello.\n\n### Fixed\n\n"
            "- Keeps **Markdown** and Polish: zgoda.\n\n"
            "[Full changes](https://example.com/compare)\n\n"
            "## [1.1.2] - 2026-09-01\nOld\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Hello.\n\n### Fixed\n\n"
                         "- Keeps **Markdown** and Polish: zgoda.\n\n"
                         "[Full changes](https://example.com/compare)\n")

    def test_accepts_tag_and_beta_version(self):
        result = self.extract("## [1.2.0-beta.1] - 2026-09-20\n\nPreview.\n", "v1.2.0-beta.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Preview.\n")

    def test_missing_empty_and_duplicate_entries_fail_without_output(self):
        for text in ["# Changelog\n", "## [1.2.0] - 2026-09-20\n\n",
                     "## [1.2.0] - 2026-09-20\nOne\n## [1.2.0] - 2026-09-21\nTwo\n"]:
            with self.subTest(text=text):
                result = self.extract(text)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertTrue(result.stderr)

    def test_invalid_version_and_date_fail(self):
        for version, heading in [("1.2", "1.2"), ("1.2.0.*", "1.2.0"),
                                 ("../1.2.0", "1.2.0")]:
            with self.subTest(version=version):
                result = self.extract(f"## [{heading}] - 2026-09-20\nBody\n", version)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        result = self.extract("## [1.2.0] - 2026-02-31\nBody\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_missing_file_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(SCRIPT), "1.2.0",
                                     str(Path(directory) / "missing.md")], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
