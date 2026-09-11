import importlib.util
import hashlib
import json
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
LICENSES = (
    "FFmpeg-LGPL-2.1.txt",
    "GPL-3.0-or-later.txt",
    "LAME-LGPL-2.0.txt",
    "QuickJS-MIT.txt",
    "yt-dlp-THIRD_PARTY_LICENSES.txt",
    "yt-dlp-Unlicense.txt",
)


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
        self.team_id = "TEAM123456"
        self.authority = "Developer ID Application: Test (TEAM123456)"

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
            if "-dv" in command:
                return self.completed(
                    command,
                    stderr=(
                        f"Authority={self.authority}\n"
                        f"TeamIdentifier={self.team_id}\n"
                    ),
                )
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
        self.inventory = self.root / "tools" / "macos-helper-inventory.json"

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
        for license_name in LICENSES:
            (license_root / license_name).write_text("license\n", encoding="utf-8")

        (resources / "SOURCE_AVAILABILITY.md").write_text("source index\n", encoding="utf-8")
        self.write_inventory(bundle)
        self.write_sbom(bundle)

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

    def write_inventory(self, bundle):
        helper_root = bundle / "Contents" / "Helpers"
        license_root = bundle / "Contents" / "Resources" / "ThirdPartyLicenses"
        source_helper_root = self.inventory.parent
        source_license_root = source_helper_root / "licenses"
        source_license_root.mkdir(parents=True)
        for helper in HELPERS:
            bundled_helper = helper_root / helper
            payload = (
                bundled_helper.read_bytes()
                if bundled_helper.is_file()
                else b"#!/bin/sh\nexit 0\n"
            )
            (source_helper_root / helper).write_bytes(payload)
        for license_name in LICENSES:
            (source_license_root / license_name).write_bytes(
                (license_root / license_name).read_bytes()
            )
        component_data = (
            (
                "yt-dlp",
                "yt-dlp macOS standalone",
                "2026.07.04",
                "GPL-3.0-or-later",
                ("yt-dlp_macos",),
                (
                    "GPL-3.0-or-later.txt",
                    "yt-dlp-Unlicense.txt",
                    "yt-dlp-THIRD_PARTY_LICENSES.txt",
                ),
            ),
            (
                "ffmpeg",
                "FFmpeg",
                "9.0",
                "LGPL-2.1-or-later",
                ("ffmpeg", "ffprobe"),
                ("FFmpeg-LGPL-2.1.txt",),
            ),
            (
                "lame",
                "LAME",
                "3.100",
                "LGPL-2.0-or-later",
                (),
                ("LAME-LGPL-2.0.txt",),
            ),
            (
                "quickjs",
                "QuickJS",
                "2026-06-04",
                "MIT",
                ("qjs",),
                ("QuickJS-MIT.txt",),
            ),
        )
        components = []
        for component_id, name, version, license_expression, helpers, licenses in component_data:
            component = {
                "id": component_id,
                "name": name,
                "version": version,
                "supplier": "Organization: test upstream",
                "downloadLocation": "https://example.invalid/source",
                "sourceInfo": "Pinned test source.",
                "licenseConcluded": license_expression,
                "licenseDeclared": license_expression,
                "licenseFiles": [
                    {
                        "name": license_name,
                        "sha256": hashlib.sha256((source_license_root / license_name).read_bytes()).hexdigest(),
                    }
                    for license_name in licenses
                ],
                "helpers": [
                    {
                        "name": helper,
                        "sha256": hashlib.sha256((source_helper_root / helper).read_bytes()).hexdigest(),
                        "architectures": ["arm64"],
                    }
                    for helper in helpers
                ],
            }
            if component_id == "lame":
                component["embeddedInHelpers"] = ["ffmpeg", "ffprobe"]
            components.append(component)
        self.inventory.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "platform": "macos",
                    "created": "2026-08-27T00:00:00Z",
                    "components": components,
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    def write_sbom(self, bundle, *, version_overrides=None, checksum_overrides=None):
        helper_root = bundle / "Contents" / "Helpers"
        versions = {
            "YT Downloader Pro 2": "2.0.0",
            "yt-dlp macOS standalone": "2026.07.04",
            "FFmpeg": "9.0",
            "LAME": "3.100",
            "QuickJS": "2026-06-04",
        }
        versions.update(version_overrides or {})
        checksums = {
            helper: hashlib.sha256((helper_root / helper).read_bytes()).hexdigest()
            for helper in HELPERS
            if (helper_root / helper).is_file()
        }
        checksums.update(checksum_overrides or {})
        payload = {
            "spdxVersion": "SPDX-2.3",
            "dataLicense": "CC0-1.0",
            "SPDXID": "SPDXRef-DOCUMENT",
            "name": "YT Downloader Pro 2 2.0.0 macOS SBOM",
            "documentNamespace": "https://github.com/catstayathome-collab/YT-Downloader-Pro/spdx/macos/2.0.0/test",
            "creationInfo": {
                "created": "2026-08-27T00:00:00Z",
                "creators": ["Tool: test"],
            },
            "packages": [],
            "files": [
                {
                    "SPDXID": f"SPDXRef-File-{helper.replace('_', '-')}",
                    "fileName": f"./Contents/Helpers/{helper}",
                    "checksums": [
                        {"algorithm": "SHA256", "checksumValue": checksum}
                    ],
                    "licenseConcluded": {
                        "yt-dlp_macos": "GPL-3.0-or-later",
                        "ffmpeg": "LGPL-2.1-or-later",
                        "ffprobe": "LGPL-2.1-or-later",
                        "qjs": "MIT",
                    }[helper],
                    "licenseInfoInFiles": ["NOASSERTION"],
                    "copyrightText": "NOASSERTION",
                    "comment": (
                        "Architectures: arm64; Canonical source SHA-256: "
                        + hashlib.sha256((helper_root / helper).read_bytes()).hexdigest()
                    ),
                }
                for helper, checksum in checksums.items()
            ],
            "relationships": [],
        }
        package_ids = {
            "YT Downloader Pro 2": "SPDXRef-Package-YTDownloaderPro2",
            "yt-dlp macOS standalone": "SPDXRef-Package-yt-dlp",
            "FFmpeg": "SPDXRef-Package-ffmpeg",
            "LAME": "SPDXRef-Package-lame",
            "QuickJS": "SPDXRef-Package-quickjs",
        }
        licenses = {
            "YT Downloader Pro 2": "NOASSERTION",
            "yt-dlp macOS standalone": "GPL-3.0-or-later",
            "FFmpeg": "LGPL-2.1-or-later",
            "LAME": "LGPL-2.0-or-later",
            "QuickJS": "MIT",
        }
        license_files = {
            "yt-dlp macOS standalone": (
                "GPL-3.0-or-later.txt",
                "yt-dlp-Unlicense.txt",
                "yt-dlp-THIRD_PARTY_LICENSES.txt",
            ),
            "FFmpeg": ("FFmpeg-LGPL-2.1.txt",),
            "LAME": ("LAME-LGPL-2.0.txt",),
            "QuickJS": ("QuickJS-MIT.txt",),
        }
        for name, version in versions.items():
            package = {
                "SPDXID": package_ids[name],
                "name": name,
                "versionInfo": version,
                "downloadLocation": "NOASSERTION" if name == "YT Downloader Pro 2" else "https://example.invalid/source",
                "filesAnalyzed": False,
                "licenseConcluded": licenses[name],
                "licenseDeclared": licenses[name],
                "copyrightText": "NOASSERTION",
            }
            if name != "YT Downloader Pro 2":
                package.update(
                    {
                        "supplier": "Organization: test upstream",
                        "sourceInfo": "Pinned test source.",
                        "attributionTexts": [
                            "Bundled license: Contents/Resources/ThirdPartyLicenses/"
                            + license_name
                            + " (SHA-256 "
                            + hashlib.sha256(
                                (
                                    bundle
                                    / "Contents"
                                    / "Resources"
                                    / "ThirdPartyLicenses"
                                    / license_name
                                ).read_bytes()
                            ).hexdigest()
                            + ")"
                            for license_name in license_files[name]
                        ],
                    }
                )
            payload["packages"].append(package)
        payload["relationships"].append(
            {
                "spdxElementId": "SPDXRef-DOCUMENT",
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": package_ids["YT Downloader Pro 2"],
            }
        )
        component_for_helper = {
            "yt-dlp_macos": "yt-dlp macOS standalone",
            "ffmpeg": "FFmpeg",
            "ffprobe": "FFmpeg",
            "qjs": "QuickJS",
        }
        for component in ("yt-dlp macOS standalone", "FFmpeg", "LAME", "QuickJS"):
            payload["relationships"].append(
                {
                    "spdxElementId": package_ids["YT Downloader Pro 2"],
                    "relationshipType": "DEPENDS_ON",
                    "relatedSpdxElement": package_ids[component],
                }
            )
        for helper, component in component_for_helper.items():
            payload["relationships"].append(
                {
                    "spdxElementId": f"SPDXRef-File-{helper.replace('_', '-')}",
                    "relationshipType": "GENERATED_FROM",
                    "relatedSpdxElement": package_ids[component],
                }
            )
        for helper in ("ffmpeg", "ffprobe"):
            payload["relationships"].append(
                {
                    "spdxElementId": f"SPDXRef-File-{helper}",
                    "relationshipType": "STATIC_LINK",
                    "relatedSpdxElement": package_ids["LAME"],
                }
            )
        (bundle / "Contents" / "Resources" / "SBOM.spdx.json").write_text(
            json.dumps(payload, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    @staticmethod
    def write_executable(path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        path.chmod(0o755)

    def verify(
        self,
        bundle,
        runner=None,
        architectures=("arm64",),
        signing_mode="internal",
        expected_team_id=None,
    ):
        return self.checker.verify_bundle(
            bundle,
            expected_version="2.0.0",
            expected_architectures=architectures,
            command_runner=runner or FakeCommandRunner(),
            signing_mode=signing_mode,
            expected_team_id=expected_team_id,
            inventory_path=self.inventory,
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
        self.assertFalse(
            any(Path(command[0]).name in HELPERS for command in runner.commands),
            runner.commands,
        )

    def test_developer_id_mode_rejects_wrong_team_before_executing_helpers(self):
        bundle = self.fake_bundle()
        runner = FakeCommandRunner()
        runner.team_id = "WRONGTEAM1"

        report = self.verify(
            bundle,
            runner=runner,
            signing_mode="developer-id",
            expected_team_id="TEAM123456",
        )

        self.assertTrue(any("TeamIdentifier" in error for error in report.errors), report.errors)
        self.assertFalse(
            any(Path(command[0]).name in HELPERS for command in runner.commands),
            runner.commands,
        )

    def test_rejects_missing_localization_and_resource(self):
        bundle = self.fake_bundle()
        (bundle / "Contents" / "Resources" / "zh-Hant.lproj" / "Localizable.strings").unlink()
        (bundle / "Contents" / "Resources" / "THIRD_PARTY_NOTICES.md").unlink()

        report = self.verify(bundle)

        self.assertTrue(any("zh-Hant" in error for error in report.errors), report.errors)
        self.assertTrue(any("THIRD_PARTY_NOTICES.md" in error for error in report.errors), report.errors)

    def test_rejects_missing_sbom_and_yt_dlp_license(self):
        bundle = self.fake_bundle()
        resources = bundle / "Contents" / "Resources"
        (resources / "SBOM.spdx.json").unlink()
        (resources / "ThirdPartyLicenses" / "GPL-3.0-or-later.txt").unlink()

        report = self.verify(bundle)

        self.assertTrue(any("SBOM.spdx.json" in error for error in report.errors), report.errors)
        self.assertTrue(any("GPL-3.0-or-later.txt" in error for error in report.errors), report.errors)

    def test_rejects_sbom_helper_checksum_mismatch(self):
        bundle = self.fake_bundle()
        self.write_sbom(bundle, checksum_overrides={"ffmpeg": "0" * 64})

        report = self.verify(bundle)

        self.assertTrue(any("SBOM SHA-256 mismatch" in error and "ffmpeg" in error for error in report.errors), report.errors)

    def test_rejects_sbom_helper_version_mismatch(self):
        bundle = self.fake_bundle()
        self.write_sbom(bundle, version_overrides={"QuickJS": "2025-09-13"})

        report = self.verify(bundle)

        self.assertTrue(any("SBOM version mismatch" in error and "qjs" in error for error in report.errors), report.errors)

    def test_rejects_sbom_missing_helper_file(self):
        bundle = self.fake_bundle()
        sbom_path = bundle / "Contents" / "Resources" / "SBOM.spdx.json"
        payload = json.loads(sbom_path.read_text(encoding="utf-8"))
        payload["files"] = [item for item in payload["files"] if not item["fileName"].endswith("/qjs")]
        sbom_path.write_text(json.dumps(payload) + "\n", encoding="utf-8")

        report = self.verify(bundle)

        self.assertTrue(any("SBOM helper file set" in error and "qjs" in error for error in report.errors), report.errors)

    def test_rejects_sbom_missing_required_relationship(self):
        bundle = self.fake_bundle()
        sbom_path = bundle / "Contents" / "Resources" / "SBOM.spdx.json"
        payload = json.loads(sbom_path.read_text(encoding="utf-8"))
        payload["relationships"] = []
        sbom_path.write_text(json.dumps(payload) + "\n", encoding="utf-8")

        report = self.verify(bundle)

        self.assertTrue(any("SBOM relationships" in error for error in report.errors), report.errors)

    def test_rejects_duplicate_sbom_relationship(self):
        bundle = self.fake_bundle()
        sbom_path = bundle / "Contents" / "Resources" / "SBOM.spdx.json"
        payload = json.loads(sbom_path.read_text(encoding="utf-8"))
        payload["relationships"].append(dict(payload["relationships"][0]))
        sbom_path.write_text(json.dumps(payload) + "\n", encoding="utf-8")

        report = self.verify(bundle)

        self.assertTrue(any("repeats relationship" in error for error in report.errors), report.errors)

    def test_rejects_impossible_sbom_timestamp(self):
        bundle = self.fake_bundle()
        sbom_path = bundle / "Contents" / "Resources" / "SBOM.spdx.json"
        payload = json.loads(sbom_path.read_text(encoding="utf-8"))
        payload["creationInfo"]["created"] = "2026-99-99T99:99:99Z"
        sbom_path.write_text(json.dumps(payload) + "\n", encoding="utf-8")

        report = self.verify(bundle)

        self.assertTrue(any("creationInfo.created" in error for error in report.errors), report.errors)

    def test_rejects_sbom_wrong_license_and_missing_package_field(self):
        bundle = self.fake_bundle()
        sbom_path = bundle / "Contents" / "Resources" / "SBOM.spdx.json"
        payload = json.loads(sbom_path.read_text(encoding="utf-8"))
        quickjs = next(item for item in payload["packages"] if item["name"] == "QuickJS")
        quickjs["licenseConcluded"] = "NOASSERTION"
        quickjs.pop("downloadLocation")
        sbom_path.write_text(json.dumps(payload) + "\n", encoding="utf-8")

        report = self.verify(bundle)

        self.assertTrue(any("QuickJS" in error and "licenseConcluded" in error for error in report.errors), report.errors)
        self.assertTrue(any("QuickJS" in error and "downloadLocation" in error for error in report.errors), report.errors)

    def test_rejects_self_consistent_bundle_that_disagrees_with_canonical_inventory(self):
        bundle = self.fake_bundle()
        license_path = bundle / "Contents" / "Resources" / "ThirdPartyLicenses" / "QuickJS-MIT.txt"
        license_path.write_text("replacement license\n", encoding="utf-8")
        self.write_sbom(bundle)

        report = self.verify(bundle)

        self.assertTrue(
            any("canonical inventory SHA-256 mismatch" in error and "QuickJS-MIT.txt" in error for error in report.errors),
            report.errors,
        )

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
    def run_build_script(self, *arguments):
        return subprocess.run(
            [str(BUILD_SCRIPT), *arguments],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_build_script_requires_explicit_sbom_timestamp_before_building(self):
        result = self.run_build_script("--version", "2.0.0", "--unsigned-test")

        self.assertEqual(result.returncode, 2)
        self.assertIn("--sbom-created", result.stderr)
        self.assertNotIn("Running strict Swift tests", result.stdout)

    def test_developer_id_build_requires_team_id_before_building(self):
        result = self.run_build_script(
            "--version",
            "2.0.0",
            "--sbom-created",
            "2026-08-27T00:00:00Z",
            "--signing-identity",
            "Developer ID Application: Test (TEAM123456)",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("--team-id", result.stderr)
        self.assertNotIn("Running strict Swift tests", result.stdout)

    def test_build_script_rejects_impossible_sbom_timestamp_before_building(self):
        result = self.run_build_script(
            "--version",
            "2.0.0",
            "--sbom-created",
            "2026-99-99T99:99:99Z",
            "--unsigned-test",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("--sbom-created", result.stderr)
        self.assertNotIn("Running strict Swift tests", result.stdout)

    def test_build_script_uses_project_local_clang_module_cache(self):
        self.assertTrue(BUILD_SCRIPT.is_file(), f"required script is missing: {BUILD_SCRIPT}")
        content = BUILD_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('CLANG_MODULE_CACHE_PATH="$SWIFT_DIR/.build/clang-module-cache"', content)
        self.assertIn('export CLANG_MODULE_CACHE_PATH', content)
        self.assertIn('mkdir -p "$CLANG_MODULE_CACHE_PATH"', content)

    def test_build_script_orders_preflight_verification_signing_and_archive(self):
        self.assertTrue(BUILD_SCRIPT.is_file(), f"required script is missing: {BUILD_SCRIPT}")
        content = BUILD_SCRIPT.read_text(encoding="utf-8")

        preflight = content.index("preflight_helper_architectures")
        assembly = content.index('rm -rf "$APP_PATH"')
        helper_signing = content.index('codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$helper_path"')
        sbom = content.index('generate_swift_sbom.py')
        app_signing = content.index('codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_PATH"')
        verification = content.index('check_swift_bundle.py')
        archive = content.index("--archive")
        self.assertLess(preflight, assembly)
        self.assertLess(helper_signing, app_signing)
        self.assertLess(helper_signing, sbom)
        self.assertLess(sbom, app_signing)
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
        self.assertIn("--sbom-created", content)
        self.assertIn("--team-id", content)
        self.assertIn('--signing-mode "$BUILD_KIND"', content)
        self.assertIn('--expected-team-id "$TEAM_ID"', content)
        self.assertIn('--inventory "$ROOT_DIR/tools/macos-helper-inventory.json"', content)


if __name__ == "__main__":
    unittest.main()
