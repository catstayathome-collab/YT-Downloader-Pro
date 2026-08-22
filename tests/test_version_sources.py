import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

VERSIONED_ENTRYPOINTS = {
    "v1.8.0": ("YT_downloader_180.py",),
    "v1.8.5": ("YT_downloader_185.py",),
    "v1.8.6": ("YT_downloader_186.py",),
    "v1.8.7": ("YT_downloader_187.py", "YT_downloader_187_windows.py"),
    "v1.8.8": ("YT_downloader_188.py", "YT_downloader_188_windows.py"),
}

BUILD_ENTRYPOINTS = {
    "scripts/build_1_8_1.sh": "versions/v1.8.6/YT_downloader_186.py",
    "scripts/build_1_8_7.sh": "versions/v1.8.7/YT_downloader_187.py",
    "scripts/build_1_8_8.sh": "versions/v1.8.8/YT_downloader_188.py",
    "scripts/build_windows_1_8_7.ps1": (
        "versions/v1.8.7/YT_downloader_187_windows.py"
    ),
    "scripts/build_windows_1_8_8.ps1": (
        "versions/v1.8.8/YT_downloader_188_windows.py"
    ),
}


class VersionSourceLayoutTests(unittest.TestCase):
    def test_future_python_builds_use_windows_contents_manifest(self):
        from ytdp import app

        self.assertEqual(
            app.DEFAULT_UPDATE_MANIFEST_URL,
            "https://api.github.com/repos/catstayathome-collab/YT-Downloader-Pro/contents/updates/windows.json?ref=main",
        )

    def test_split_manifests_are_valid_platform_specific_placeholders(self):
        macos = json.loads((ROOT / "updates" / "macos.json").read_text(encoding="utf-8"))
        windows = json.loads((ROOT / "updates" / "windows.json").read_text(encoding="utf-8"))

        self.assertEqual(macos["platform"], "macos")
        self.assertEqual(windows["platform"], "windows")
        self.assertEqual(macos["latest_version"], "0.0.0")
        self.assertEqual(windows["latest_version"], "0.0.0")
        self.assertIn("not a release", macos["release_notes"].lower())
        self.assertIn("not a release", windows["release_notes"].lower())
        self.assertEqual(
            [(asset["platform"], asset["architecture"]) for asset in windows["assets"]],
            [("windows", "x64")],
        )

    def test_macos_manifest_generator_is_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.json"
            second = Path(directory) / "second.json"
            common = [
                "--version", "2.0.0",
                "--minimum-macos", "13.0.0",
                "--release-url", "https://example.invalid/releases/macos-example",
                "--download-url", "https://example.invalid/macos-example.zip",
                "--sha256", "1" * 64,
                "--published-at", "2026-08-18T00:00:00Z",
                "--release-notes", "Example only; not a release.",
            ]

            subprocess.run(
                ["python3", str(ROOT / "scripts" / "create_macos_manifest.py"), *common, "--output", str(first)],
                check=True,
                cwd=ROOT,
            )
            subprocess.run(
                ["python3", str(ROOT / "scripts" / "create_macos_manifest.py"), *common, "--output", str(second)],
                check=True,
                cwd=ROOT,
            )

            self.assertEqual(first.read_bytes(), second.read_bytes())
            generated = json.loads(first.read_text(encoding="utf-8"))
            self.assertEqual(generated["platform"], "macos")
            self.assertEqual(generated["minimum_macos"], "13.0.0")
            self.assertTrue(first.read_bytes().endswith(b"\n"))

    def test_versioned_entrypoints_are_grouped_outside_the_repository_root(self):
        for version, filenames in VERSIONED_ENTRYPOINTS.items():
            for filename in filenames:
                with self.subTest(version=version, filename=filename):
                    self.assertTrue(
                        (ROOT / "versions" / version / filename).is_file(),
                        f"missing versions/{version}/{filename}",
                    )

        self.assertEqual(list(ROOT.glob("YT_downloader_*.py")), [])

    def test_version_index_explains_tags_and_shared_source_history(self):
        index = (ROOT / "versions" / "README.md").read_text(encoding="utf-8")

        for version in ("1.8.0", "1.8.1", "1.8.2", "1.8.3", "1.8.4", "1.8.5", "1.8.6", "1.8.7", "1.8.8"):
            with self.subTest(version=version):
                self.assertIn(version, index)
        for expected in (
            "Git tag",
            "1.8.1 至 1.8.4",
            "ytdp/",
            "完整版本",
        ):
            self.assertIn(expected, index)

    def test_standalone_1_8_7_source_is_archived_and_documented(self):
        archive = (
            ROOT
            / "versions"
            / "v1.8.7"
            / "YT_downloader_187_standalone.py"
        )
        self.assertTrue(archive.is_file())

        index = (ROOT / "versions" / "README.md").read_text(encoding="utf-8")
        self.assertIn("YT_downloader_187_standalone.py", index)
        self.assertIn("獨立版封存", index)

    def test_build_scripts_use_the_grouped_entrypoints(self):
        for script_name, entrypoint in BUILD_ENTRYPOINTS.items():
            with self.subTest(script=script_name):
                script = (ROOT / script_name).read_text(encoding="utf-8")
                self.assertIn(entrypoint, script)

    def test_windows_workflows_watch_the_grouped_entrypoints(self):
        expected = {
            ".github/workflows/windows-1.8.7.yml": (
                "versions/v1.8.7/YT_downloader_187_windows.py"
            ),
            ".github/workflows/windows-1.8.8.yml": (
                "versions/v1.8.8/YT_downloader_188_windows.py"
            ),
        }

        for workflow_name, entrypoint in expected.items():
            with self.subTest(workflow=workflow_name):
                workflow = (ROOT / workflow_name).read_text(encoding="utf-8")
                self.assertIn(entrypoint, workflow)


if __name__ == "__main__":
    unittest.main()
