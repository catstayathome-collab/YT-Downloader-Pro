import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "windows-1.8.7.yml"
ARTIFACT_NAME = "YT-Downloader-Pro-v1.8.7-Windows-x64"
ACTION_REFS = {
    "actions/checkout": "3d3c42e5aac5ba805825da76410c181273ba90b1",
    "actions/setup-python": "5fda3b95a4ea91299a34e894583c3862153e4b97",
    "actions/upload-artifact": "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
}
ACTION_VERSIONS = {
    "actions/checkout": "v7.0.1",
    "actions/setup-python": "v7.0.0",
    "actions/upload-artifact": "v7.0.1",
}
PR_PATHS = {
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
    "requirements-test.txt",
    "tests/**",
}
ARTIFACT_PATHS = {
    f"dist/{ARTIFACT_NAME}.zip",
    f"dist/{ARTIFACT_NAME}.zip.sha256",
    "dist/windows-self-test.json",
    "dist/windows-extracted-self-test.json",
    "dist/windows-package-report.json",
    "tools/windows-tools.json",
}


def step_named(steps, name):
    matches = [step for step in steps if step.get("name") == name]
    if len(matches) != 1:
        raise AssertionError(f"expected exactly one step named {name!r}; found {len(matches)}")
    return matches[0]


def walk_mappings(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk_mappings(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_mappings(child)


class WindowsWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text(encoding="utf-8")
        cls.workflow = yaml.safe_load(cls.source)
        cls.triggers = cls.workflow["on"]
        cls.job = cls.workflow["jobs"]["build-windows"]
        cls.steps = cls.job["steps"]

    def test_workflow_has_only_manual_and_filtered_pull_request_triggers(self):
        self.assertEqual(set(self.triggers), {"workflow_dispatch", "pull_request"})
        self.assertIsNone(self.triggers["workflow_dispatch"])
        self.assertEqual(set(self.triggers["pull_request"]), {"paths"})
        self.assertEqual(set(self.triggers["pull_request"]["paths"]), PR_PATHS)

    def test_workflow_uses_read_only_permissions_and_one_windows_job(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertEqual(set(self.workflow["jobs"]), {"build-windows"})
        self.assertEqual(self.job["runs-on"], "windows-2022")

        for mapping in walk_mappings(self.workflow):
            permissions = mapping.get("permissions")
            if permissions is not None:
                values = permissions.values() if isinstance(permissions, dict) else [permissions]
                for value in values:
                    self.assertNotIn("write", str(value).casefold())

    def test_workflow_uses_reviewed_immutable_action_revisions_with_release_comments(self):
        action_steps = [step["uses"] for step in self.steps if "uses" in step]
        self.assertEqual(
            action_steps,
            [f"{action}@{revision}" for action, revision in ACTION_REFS.items()],
        )

        for action, revision in ACTION_REFS.items():
            self.assertIn(
                f"uses: {action}@{revision} # {ACTION_VERSIONS[action]}",
                self.source,
            )

    def test_workflow_installs_runtime_and_test_requirements_before_all_unit_tests(self):
        runtime = step_named(self.steps, "Install exact requirements")
        test = step_named(self.steps, "Install exact test requirements")
        unit_tests = step_named(self.steps, "Run unit tests")
        build = step_named(self.steps, "Build Windows package")

        self.assertEqual(runtime["run"], "python -m pip install --requirement requirements.txt")
        self.assertEqual(test["run"], "python -m pip install --requirement requirements-test.txt")
        self.assertEqual(unit_tests["run"], "python -m unittest discover -s tests -v")
        self.assertLess(self.steps.index(runtime), self.steps.index(test))
        self.assertLess(self.steps.index(test), self.steps.index(unit_tests))
        self.assertLess(self.steps.index(unit_tests), self.steps.index(build))

    def test_clean_extraction_waits_for_the_exe_and_validates_its_report(self):
        verify = step_named(self.steps, "Verify the final ZIP from a clean extraction")
        script = verify["run"]

        for expected in (
            "Get-FileHash",
            ".sha256",
            "Expand-Archive",
            "RUNNER_TEMP",
            "[guid]::NewGuid()",
            "scripts/check_windows_package.py",
            "$process = Start-Process -FilePath $extractedExe",
            "-ArgumentList @('--self-test', '--self-test-report', $extractedSelfTest)",
            "-Wait",
            "-PassThru",
            "$process.ExitCode",
            "ConvertFrom-Json",
            "status -ne 'ok'",
        ):
            self.assertIn(expected, script)

        process_block = script[script.index("$process = Start-Process"):]
        self.assertNotIn("$LASTEXITCODE", process_block)
        self.assertLess(script.index("Expand-Archive"), script.index("scripts/check_windows_package.py"))
        self.assertLess(script.index("scripts/check_windows_package.py"), script.index("$process = Start-Process"))

    def test_workflow_uploads_exactly_one_verified_artifact_and_has_no_release_step(self):
        upload_steps = [
            step
            for step in self.steps
            if step.get("uses", "").split("@", 1)[0] == "actions/upload-artifact"
        ]
        self.assertEqual(len(upload_steps), 1)
        upload = upload_steps[0]
        self.assertEqual(upload["uses"], f"actions/upload-artifact@{ACTION_REFS['actions/upload-artifact']}")
        self.assertEqual(upload["with"]["name"], ARTIFACT_NAME)
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        artifact_paths = [path for path in upload["with"]["path"].splitlines() if path]
        self.assertEqual(len(artifact_paths), 6)
        self.assertEqual(set(artifact_paths), ARTIFACT_PATHS)

        for step in self.steps:
            self.assertNotIn("release", step.get("uses", "").casefold())
            self.assertNotRegex(step.get("run", ""), r"(?im)\b(?:gh|github)\s+release\b")


if __name__ == "__main__":
    unittest.main()
