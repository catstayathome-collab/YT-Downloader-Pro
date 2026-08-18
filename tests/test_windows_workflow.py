import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "windows-1.8.7.yml"
ARTIFACT_NAME = "YT-Downloader-Pro-v1.8.7-Windows-x64"


def indented_block(text, header, indentation):
    """Return one YAML block, bounded by the next peer indentation level."""
    match = re.search(
        rf"^{re.escape(indentation)}{re.escape(header)}:\n(?P<body>.*?)(?=^{re.escape(indentation)}[^\s#][^\n]*:|\Z)",
        text,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"missing YAML block: {header}")
    return match.group("body")


class WindowsWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.on_block = indented_block(cls.workflow, "on", "")
        cls.jobs_block = indented_block(cls.workflow, "jobs", "")
        cls.build_job = indented_block(cls.jobs_block, "build-windows", "  ")

    def test_workflow_is_manually_dispatchable_and_limits_pull_requests_to_windows_shared_files(self):
        self.assertIsNotNone(re.search(r"^  workflow_dispatch:\s*$", self.on_block, flags=re.MULTILINE))
        pull_request = indented_block(self.on_block, "pull_request", "  ")
        paths = indented_block(pull_request, "paths", "    ")

        for expected_path in (
            ".github/workflows/windows-1.8.7.yml",
            "YT_downloader_187_windows.py",
            "ytdp/**",
            "scripts/build_windows_1_8_7.ps1",
            "scripts/check_windows_package.py",
            "scripts/fetch_windows_tools.py",
            "scripts/generate_windows_icon.py",
            "tools/windows-tools.json",
            "tools/licenses/**",
            "assets/AppIcon-1024.png",
            "README-Windows.txt",
            "THIRD_PARTY_NOTICES.md",
            "docs/WINDOWS_TEST_CHECKLIST.md",
            "requirements.txt",
            "tests/**",
        ):
            self.assertIn(f"- '{expected_path}'", paths)

    def test_workflow_uses_pinned_windows_x64_runner_and_python(self):
        self.assertIn("runs-on: windows-2022", self.build_job)
        self.assertIn("uses: actions/checkout@v5", self.build_job)

        setup_step = re.search(
            r"^      - name: Set up Python\n(?P<body>.*?)(?=^      - |\Z)",
            self.build_job,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(setup_step)
        self.assertIn("uses: actions/setup-python@v6", setup_step.group("body"))
        self.assertIn("python-version: '3.13'", setup_step.group("body"))
        self.assertIn("architecture: x64", setup_step.group("body"))
        self.assertIn("cache: pip", setup_step.group("body"))
        self.assertIn("cache-dependency-path: requirements.txt", setup_step.group("body"))

    def test_workflow_installs_exact_requirements_and_runs_all_unit_tests_before_packaging(self):
        install_index = self.build_job.index("python -m pip install --requirement requirements.txt")
        tests_index = self.build_job.index("python -m unittest discover -s tests -v")
        build_index = self.build_job.index("scripts/build_windows_1_8_7.ps1")

        self.assertLess(install_index, tests_index)
        self.assertLess(tests_index, build_index)

    def test_workflow_verifies_a_clean_extraction_and_both_self_test_reports(self):
        verification_step = re.search(
            r"^      - name: Verify the final ZIP from a clean extraction\n(?P<body>.*?)(?=^      - |\Z)",
            self.build_job,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(verification_step)
        script = verification_step.group("body")

        self.assertIn("Get-FileHash", script)
        self.assertIn(".sha256", script)
        self.assertIn("Expand-Archive", script)
        self.assertIn("RUNNER_TEMP", script)
        self.assertIn("[guid]::NewGuid()", script)
        self.assertIn("scripts/check_windows_package.py", script)
        self.assertIn("YT Downloader Pro.exe", script)
        self.assertIn("--self-test --self-test-report", script)
        self.assertIn("ConvertFrom-Json", script)
        self.assertIn("status -ne 'ok'", script)
        self.assertIn("windows-self-test.json", script)
        self.assertIn("windows-extracted-self-test.json", script)
        self.assertIn("windows-package-report.json", script)

        self.assertLess(script.index("Expand-Archive"), script.index("scripts/check_windows_package.py"))
        self.assertLess(script.index("scripts/check_windows_package.py"), script.index("--self-test --self-test-report"))

    def test_workflow_uploads_only_the_verified_ci_artifact_without_release_actions(self):
        upload_step = re.search(
            r"^      - name: Upload verified Windows artifact\n(?P<body>.*?)(?=^      - |\Z)",
            self.build_job,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(upload_step)
        artifact = upload_step.group("body")

        self.assertIn("uses: actions/upload-artifact@v4", artifact)
        self.assertIn(f"name: {ARTIFACT_NAME}", artifact)
        for expected_path in (
            f"dist/{ARTIFACT_NAME}.zip",
            f"dist/{ARTIFACT_NAME}.zip.sha256",
            "dist/windows-self-test.json",
            "dist/windows-extracted-self-test.json",
            "dist/windows-package-report.json",
            "tools/windows-tools.json",
        ):
            self.assertIn(expected_path, artifact)

        self.assertNotRegex(self.workflow, r"(?im)^\s*uses:\s*(?:softprops/action-gh-release|ncipollo/release-action)@")
        self.assertNotRegex(self.workflow, r"(?im)^\s*gh\s+release\s+")


if __name__ == "__main__":
    unittest.main()
