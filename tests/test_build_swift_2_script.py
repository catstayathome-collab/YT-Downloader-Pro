import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "scripts" / "build_swift_2.sh"
ACTIVE_PACKAGING_DOCS = (
    ROOT / "README.md",
    ROOT / "docs" / "SWIFT_2_TEST_CHECKLIST.md",
    ROOT / "docs" / "swift-2.0" / "DEVELOPMENT.md",
    ROOT / "docs" / "swift-2.0" / "RELEASE.md",
    ROOT / "docs" / "swift-2.0" / "SBOM_AND_LICENSES.md",
    ROOT / "docs" / "swift-2.0" / "TROUBLESHOOTING.md",
)


class SwiftBuildChannelContractTests(unittest.TestCase):
    def run_build_script(self, *arguments):
        return subprocess.run(
            [str(BUILD_SCRIPT), *arguments],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def capture_swift_invocations(self, app_channel):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            script_copy = temporary_root / "scripts" / BUILD_SCRIPT.name
            script_copy.parent.mkdir(parents=True)
            script_copy.write_bytes(BUILD_SCRIPT.read_bytes())
            script_copy.chmod(0o755)

            tools_directory = temporary_root / "tools"
            tools_directory.mkdir()
            for helper_name in ("yt-dlp_macos", "ffmpeg", "ffprobe", "qjs"):
                os.link(ROOT / "tools" / helper_name, tools_directory / helper_name)

            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            invocation_log = temporary_root / "swift-invocations.log"
            fake_swift = fake_bin / "swift"
            fake_swift.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >> \"$YTDP_FAKE_SWIFT_LOG\"\n"
                "case \" $* \" in\n"
                "  *' --show-bin-path '*) exit 73 ;;\n"
                "esac\n"
                "exit 0\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            environment["YTDP_FAKE_SWIFT_LOG"] = str(invocation_log)

            result = subprocess.run(
                [
                    str(script_copy),
                    "--app-channel",
                    app_channel,
                    "--version",
                    "2.0.1",
                    "--sbom-created",
                    "2026-09-23T00:00:00Z",
                    "--unsigned-test",
                ],
                cwd=temporary_root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            invocations = invocation_log.read_text(encoding="utf-8").splitlines()
        return result, invocations

    def test_build_requires_explicit_app_channel_before_running_tests(self):
        result = self.run_build_script(
            "--version",
            "2.0.1",
            "--sbom-created",
            "2026-09-23T00:00:00Z",
            "--unsigned-test",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("--app-channel", result.stderr)
        self.assertNotIn("Running strict Swift tests", result.stdout)

    def test_build_rejects_unknown_app_channel_before_running_tests(self):
        result = self.run_build_script(
            "--app-channel",
            "preview",
            "--version",
            "2.0.1",
            "--sbom-created",
            "2026-09-23T00:00:00Z",
            "--unsigned-test",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("unsupported --app-channel", result.stderr)
        self.assertNotIn("Running strict Swift tests", result.stdout)

    def test_build_rejects_repeated_app_channel_before_running_tests(self):
        result = self.run_build_script(
            "--app-channel",
            "public",
            "--app-channel",
            "internal-test",
            "--version",
            "invalid",
            "--sbom-created",
            "2026-09-23T00:00:00Z",
            "--unsigned-test",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("--app-channel may be specified only once", result.stderr)
        self.assertNotIn("Running strict Swift tests", result.stdout)

    def test_internal_compile_flag_is_wired_only_through_channel_flags(self):
        content = BUILD_SCRIPT.read_text(encoding="utf-8")

        self.assertEqual(content.count("-DYTDP_INTERNAL_TEST"), 1)
        self.assertIn("internal-test)", content)
        self.assertIn('SWIFT_CHANNEL_FLAGS=(-Xswiftc -DYTDP_INTERNAL_TEST)', content)
        self.assertGreaterEqual(
            content.count('${SWIFT_CHANNEL_FLAGS[@]+"${SWIFT_CHANNEL_FLAGS[@]}"}'),
            3,
        )

    def test_actual_swift_invocations_are_channel_specific(self):
        public_result, public_invocations = self.capture_swift_invocations("public")
        internal_result, internal_invocations = self.capture_swift_invocations(
            "internal-test"
        )

        self.assertEqual(public_result.returncode, 73, public_result.stderr)
        self.assertEqual(internal_result.returncode, 73, internal_result.stderr)
        self.assertEqual(len(public_invocations), 3)
        self.assertEqual(len(internal_invocations), 3)
        self.assertTrue(all("-DYTDP_INTERNAL_TEST" not in line for line in public_invocations))
        self.assertTrue(
            all("-Xswiftc -DYTDP_INTERNAL_TEST" in line for line in internal_invocations)
        )
        self.assertNotIn("unbound variable", public_result.stderr)

    def test_channel_is_written_to_metadata_and_all_artifact_paths(self):
        content = BUILD_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('CHANNEL_DIST_DIR="$DIST_ROOT/$APP_CHANNEL"', content)
        self.assertIn('APP_PATH="$CHANNEL_DIST_DIR/$APP_NAME.app"', content)
        self.assertIn('REPORT_PATH="$CHANNEL_DIST_DIR/swift-2.0-$APP_CHANNEL-bundle-report.json"', content)
        self.assertIn('$ARCHITECTURE_LABEL-$APP_CHANNEL.zip', content)
        self.assertIn('<key>YTDPBuildChannel</key>', content)
        self.assertIn('<string>$APP_CHANNEL</string>', content)
        self.assertIn('--expected-app-channel "$APP_CHANNEL"', content)

    def test_channel_validation_precedes_tests_and_artifact_replacement(self):
        content = BUILD_SCRIPT.read_text(encoding="utf-8")

        validation = content.index('case "$APP_CHANNEL" in')
        tests = content.index("Running strict Swift tests")
        replacement = content.index('rm -rf "$CHANNEL_DIST_DIR"')
        self.assertLess(validation, tests)
        self.assertLess(validation, replacement)

    def test_active_packaging_docs_use_explicit_channel_contract(self):
        for path in ACTIVE_PACKAGING_DOCS:
            content = path.read_text(encoding="utf-8")
            with self.subTest(path=path):
                self.assertNotIn("dist/YT Downloader Pro 2.app", content)
                self.assertNotIn("dist/swift-2.0-bundle-report.json", content)
                self.assertNotIn("macOS-arm64-internal.zip", content)

                build_offset = 0
                while True:
                    build_offset = content.find("./scripts/build_swift_2.sh", build_offset)
                    if build_offset < 0:
                        break
                    self.assertIn(
                        "--app-channel",
                        content[build_offset : build_offset + 420],
                    )
                    build_offset += 1

                checker_offset = 0
                while True:
                    checker_offset = content.find(
                        "python3 scripts/check_swift_bundle.py",
                        checker_offset,
                    )
                    if checker_offset < 0:
                        break
                    self.assertIn(
                        "--expected-app-channel",
                        content[checker_offset : checker_offset + 520],
                    )
                    checker_offset += 1


if __name__ == "__main__":
    unittest.main()
