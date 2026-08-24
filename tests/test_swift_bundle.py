import importlib.util
import hashlib
import os
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts" / "check_swift_bundle.py"
BUILD_SCRIPT = ROOT / "scripts" / "build_swift_2.sh"
APP_NAME = "YT Downloader Pro 2.app"
EXECUTABLE_NAME = "YT Downloader Pro 2"
HELPERS = ("yt-dlp_macos", "ffmpeg", "ffprobe", "qjs")
LOCALES = ("en", "ja", "zh-Hant")


def load_checker():
    if not CHECKER.is_file():
        raise AssertionError(f"required script is missing: {CHECKER}")
    spec = importlib.util.spec_from_file_location("check_swift_bundle", CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeCommandRunner:
    def __init__(self):
        self.commands = []
        self.architectures = {}
        self.ffmpeg_version = "9.0"
        self.ffprobe_version = "9.0"
        self.signature_failure = None

    def __call__(self, command, **kwargs):
        command = tuple(str(part) for part in command)
        self.commands.append(command)
        executable = Path(command[0])

        if executable.name == "lipo":
            target = Path(command[-1])
            arches = self.architectures.get(target.name, ("arm64",))
            return self.completed(command, stdout=" ".join(arches) + "\n")

        if executable.name == "codesign":
            target = Path(command[-1])
            if self.signature_failure == target.name:
                return self.completed(command, returncode=1, stderr="invalid signature")
            return self.completed(command)

        if executable.name == "otool" and "-L" in command:
            target = command[-1]
            if Path(target).name == "yt-dlp_macos":
                return self.completed(
                    command,
                    stdout=(
                        f"{target} (architecture x86_64):\n"
                        "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
                        f"{target} (architecture arm64):\n"
                        "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
                    ),
                )
            return self.completed(
                command,
                stdout=f"{target}:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n",
            )

        if executable.name == "otool" and "-l" in command:
            target = Path(command[-1])
            minimum = "13.0" if target.name == EXECUTABLE_NAME else "11.0"
            return self.completed(command, stdout=f"Load command 1\n      cmd LC_BUILD_VERSION\n    minos {minimum}\n")

        target = executable.name
        if target == "yt-dlp_macos":
            return self.completed(command, stdout="2026.07.04\n")
        if target == "ffmpeg":
            return self.completed(command, stdout=f"ffmpeg version {self.ffmpeg_version}\n")
        if target == "ffprobe":
            return self.completed(command, stdout=f"ffprobe version {self.ffprobe_version}\n")
        if target == "qjs":
            return self.completed(command, returncode=1, stdout="QuickJS version 2026-06-04\n")
        return self.completed(command, returncode=1, stderr=f"unexpected command: {command}")

    @staticmethod
    def completed(command, returncode=0, stdout="", stderr=""):
        return subprocess.CompletedProcess(command, returncode, stdout, stderr)


class SwiftBundleVerifierTests(unittest.TestCase):
    def setUp(self):
        self.checker = load_checker()
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def fake_bundle(self, helpers=HELPERS):
        bundle = self.root / APP_NAME
        macos = bundle / "Contents" / "MacOS"
        helper_root = bundle / "Contents" / "Helpers"
        resources = bundle / "Contents" / "Resources"
        for directory in (macos, helper_root, resources):
            directory.mkdir(parents=True, exist_ok=True)

        self.write_executable(macos / EXECUTABLE_NAME)
        for helper in helpers:
            self.write_executable(helper_root / helper)

        metadata = {
            "CFBundleDisplayName": "YT Downloader Pro 2",
            "CFBundleExecutable": EXECUTABLE_NAME,
            "CFBundleIconFile": "AppIcon.icns",
            "CFBundleIdentifier": "com.tachouweng.ytdownloaderpro2",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "2.0.0",
            "CFBundleVersion": "2.0.0",
            "LSMinimumSystemVersion": "13.0",
        }
        with (bundle / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(metadata, handle)

        (resources / "AppIcon.icns").write_bytes(b"icns-test")
        (resources / "THIRD_PARTY_NOTICES.md").write_text("notices\n", encoding="utf-8")
        license_root = resources / "ThirdPartyLicenses"
        license_root.mkdir()
        for license_name in (
            "FFmpeg-LGPL-2.1.txt",
            "LAME-LGPL-2.0.txt",
            "QuickJS-MIT.txt",
        ):
            (license_root / license_name).write_text("license\n", encoding="utf-8")

        (resources / "AppMetadata.json").write_text("{}\n", encoding="utf-8")
        for locale in LOCALES:
            localized = resources / f"{locale}.lproj" / "Localizable.strings"
            localized.parent.mkdir()
            localized.write_text('"app.name" = "YT Downloader Pro 2";\n', encoding="utf-8")
        (resources / "Localizable.xcstrings").write_text(
            '{"sourceLanguage":"en","strings":{},"version":"1.0"}\n',
            encoding="utf-8",
        )
        return bundle

    @staticmethod
    def write_executable(path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        path.chmod(0o755)

    def verify(self, bundle, runner=None, architectures=("arm64",)):
        return self.checker.verify_bundle(
            bundle,
            expected_version="2.0.0",
            expected_architectures=architectures,
            command_runner=runner or FakeCommandRunner(),
        )

    def test_accepts_complete_arm64_bundle_and_qjs_exit_one(self):
        report = self.verify(self.fake_bundle())

        self.assertTrue(report.ok, report.errors)
        self.assertEqual(report.architectures, ("arm64",))
        self.assertEqual(tuple(report.helper_versions), HELPERS)

    def test_requires_all_four_helpers(self):
        bundle = self.fake_bundle(helpers=("yt-dlp_macos", "ffmpeg", "ffprobe"))

        report = self.verify(bundle)

        self.assertTrue(any("qjs" in error for error in report.errors), report.errors)

    def test_rejects_duplicate_physical_ffmpeg_outside_helpers(self):
        bundle = self.fake_bundle()
        self.write_executable(bundle / "Contents" / "Frameworks" / "ffmpeg")

        report = self.verify(bundle)

        self.assertTrue(any("duplicate" in error.lower() and "ffmpeg" in error for error in report.errors), report.errors)
        self.assertTrue(any("outside Contents/Helpers" in error for error in report.errors), report.errors)

    def test_rejects_hard_link_inode_alias_across_bundle(self):
        bundle = self.fake_bundle()
        alias = bundle / "Contents" / "Resources" / "ffmpeg-copy"
        os.link(bundle / "Contents" / "Helpers" / "ffmpeg", alias)

        report = self.verify(bundle)

        self.assertTrue(any("inode" in error.lower() for error in report.errors), report.errors)

    def test_rejects_symlink_and_never_executes_external_target(self):
        bundle = self.fake_bundle(helpers=("yt-dlp_macos", "ffprobe", "qjs"))
        external = self.root / "outside-ffmpeg"
        self.write_executable(external)
        (bundle / "Contents" / "Helpers" / "ffmpeg").symlink_to(external)
        runner = FakeCommandRunner()

        report = self.verify(bundle, runner=runner)

        self.assertTrue(any("symbolic link" in error.lower() for error in report.errors), report.errors)
        executed = [command[0] for command in runner.commands if Path(command[0]).name == "outside-ffmpeg"]
        self.assertEqual(executed, [])
        self.assertFalse(
            any(Path(command[0]).name == "ffmpeg" and command[0].startswith(str(bundle)) for command in runner.commands),
            runner.commands,
        )

    def test_rejects_unexpected_fifth_helper(self):
        bundle = self.fake_bundle()
        self.write_executable(bundle / "Contents" / "Helpers" / "node")

        report = self.verify(bundle)

        self.assertTrue(any("exactly" in error and "node" in error for error in report.errors), report.errors)

    def test_rejects_mismatched_requested_architecture(self):
        bundle = self.fake_bundle()
        runner = FakeCommandRunner()
        runner.architectures["yt-dlp_macos"] = ("arm64", "x86_64")

        report = self.verify(bundle, runner=runner, architectures=("arm64", "x86_64"))

        self.assertTrue(any("x86_64" in error and "ffmpeg" in error for error in report.errors), report.errors)
        self.assertFalse(report.ok)

    def test_rejects_ffmpeg_ffprobe_version_disagreement(self):
        bundle = self.fake_bundle()
        runner = FakeCommandRunner()
        runner.ffprobe_version = "8.1.2"

        report = self.verify(bundle, runner=runner)

        self.assertTrue(any("versions do not match" in error for error in report.errors), report.errors)

    def test_rejects_invalid_helper_signature(self):
        bundle = self.fake_bundle()
        runner = FakeCommandRunner()
        runner.signature_failure = "qjs"

        report = self.verify(bundle, runner=runner)

        self.assertTrue(any("signature" in error.lower() and "qjs" in error for error in report.errors), report.errors)

    def test_rejects_missing_localization_and_resource(self):
        bundle = self.fake_bundle()
        (bundle / "Contents" / "Resources" / "zh-Hant.lproj" / "Localizable.strings").unlink()
        (bundle / "Contents" / "Resources" / "THIRD_PARTY_NOTICES.md").unlink()

        report = self.verify(bundle)

        self.assertTrue(any("zh-Hant" in error for error in report.errors), report.errors)
        self.assertTrue(any("THIRD_PARTY_NOTICES.md" in error for error in report.errors), report.errors)

    def test_rejects_wrong_info_plist_versions(self):
        bundle = self.fake_bundle()
        info_path = bundle / "Contents" / "Info.plist"
        with info_path.open("rb") as handle:
            metadata = plistlib.load(handle)
        metadata["CFBundleVersion"] = "199"
        metadata["LSMinimumSystemVersion"] = "12.0"
        with info_path.open("wb") as handle:
            plistlib.dump(metadata, handle)

        report = self.verify(bundle)

        self.assertTrue(any("CFBundleVersion" in error for error in report.errors), report.errors)
        self.assertTrue(any("LSMinimumSystemVersion" in error for error in report.errors), report.errors)

    def test_rejects_writable_application_state_inside_bundle(self):
        bundle = self.fake_bundle()
        state = bundle / "Contents" / "Resources" / "State" / "downloads.previous"
        state.parent.mkdir()
        state.write_text("state", encoding="utf-8")

        report = self.verify(bundle)

        self.assertTrue(any("writable app-state" in error for error in report.errors), report.errors)

    def test_json_report_is_deterministic(self):
        bundle = self.fake_bundle()

        first = self.verify(bundle).to_json()
        second = self.verify(bundle).to_json()

        self.assertEqual(first, second)
        self.assertTrue(first.endswith("\n"))

    def test_internal_zip_is_byte_deterministic_and_preserves_executable_modes(self):
        bundle = self.fake_bundle()
        first = self.root / "first.zip"
        second = self.root / "second.zip"

        self.checker.write_deterministic_zip(bundle, first)
        self.checker.write_deterministic_zip(bundle, second)

        self.assertEqual(hashlib.sha256(first.read_bytes()).digest(), hashlib.sha256(second.read_bytes()).digest())
        with zipfile.ZipFile(first) as archive:
            names = archive.namelist()
            self.assertEqual(names, sorted(names))
            self.assertTrue(all(info.date_time == (2000, 1, 1, 0, 0, 0) for info in archive.infolist()))
            executable = archive.getinfo(f"{APP_NAME}/Contents/MacOS/{EXECUTABLE_NAME}")
            self.assertEqual((executable.external_attr >> 16) & 0o777, 0o755)


class SwiftBuildScriptContractTests(unittest.TestCase):
    def test_build_script_orders_preflight_verification_signing_and_archive(self):
        self.assertTrue(BUILD_SCRIPT.is_file(), f"required script is missing: {BUILD_SCRIPT}")
        content = BUILD_SCRIPT.read_text(encoding="utf-8")

        preflight = content.index("preflight_helper_architectures")
        assembly = content.index('rm -rf "$APP_PATH"')
        helper_signing = content.index('codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$helper_path"')
        app_signing = content.index('codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_PATH"')
        verification = content.index('check_swift_bundle.py')
        archive = content.index("--archive")
        self.assertLess(preflight, assembly)
        self.assertLess(helper_signing, app_signing)
        self.assertLess(app_signing, verification)
        self.assertLess(verification, archive)

    def test_build_script_compiles_all_localizations_and_clears_only_copied_files(self):
        self.assertTrue(BUILD_SCRIPT.is_file(), f"required script is missing: {BUILD_SCRIPT}")
        content = BUILD_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("xcstringstool compile", content)
        for locale in LOCALES:
            self.assertIn(f'--language "{locale}"', content)
        self.assertIn('find "$APP_PATH" -type f -exec xattr -d com.apple.quarantine', content)
        self.assertNotIn('xattr -cr "$ROOT_DIR/tools"', content)
        self.assertIn('"$RESOURCES_DIR/Localizable.xcstrings"', content)
        self.assertNotIn('/bin/cp -R "$RESOURCE_BUNDLE"', content)
        self.assertIn("-strict-concurrency=complete", content)
        self.assertIn("-warnings-as-errors", content)


if __name__ == "__main__":
    unittest.main()
