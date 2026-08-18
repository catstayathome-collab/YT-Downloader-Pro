import importlib.util
import hashlib
import io
import json
import ssl
import struct
import tempfile
import unittest
import warnings
import zipfile
from email.message import Message
from pathlib import Path
from urllib import request, response


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tools" / "windows-tools.json"
PACKAGE_CHECKER = ROOT / "scripts" / "check_windows_package.py"
TOOL_FETCHER = ROOT / "scripts" / "fetch_windows_tools.py"
ICON_GENERATOR = ROOT / "scripts" / "generate_windows_icon.py"
TRACKED_ICON = ROOT / "assets" / "AppIcon.ico"
BUILD_SCRIPT = ROOT / "scripts" / "build_windows_1_8_8.ps1"
WINDOWS_WORKFLOW = ROOT / ".github" / "workflows" / "windows-1.8.8.yml"
LEGACY_BUILD_SCRIPT = ROOT / "scripts" / "build_windows_1_8_7.ps1"
LEGACY_WORKFLOW = ROOT / ".github" / "workflows" / "windows-1.8.7.yml"
PACKAGE_NAME = "YT-Downloader-Pro-v1.8.8-Windows-x64"
APP_EXE = "YT Downloader Pro.exe"
ICON_DIMENSIONS = (16, 24, 32, 48, 64, 128, 256)
EXPECTED_MANIFEST = {
    "ffmpeg": {
        "version": "N-126086-ge5ecfe8970",
        "url": (
            "https://github.com/BtbN/FFmpeg-Builds/releases/download/"
            "autobuild-2026-08-12-13-15/"
            "ffmpeg-N-126086-ge5ecfe8970-win64-lgpl.zip"
        ),
        "sha256": "3fe180f31a12a1de60568cdcf72210a1d3f475f5f88719afdd6c7012e13f6d3e",
        "upstream": "https://github.com/BtbN/FFmpeg-Builds",
        "license": "LGPL-2.1-or-later",
        "license_file": "tools/licenses/FFmpeg-LGPL-2.1.txt",
        "archive_members": [
            {
                "path": "ffmpeg-N-126086-ge5ecfe8970-win64-lgpl/bin/ffmpeg.exe",
                "output_name": "ffmpeg.exe",
            },
            {
                "path": "ffmpeg-N-126086-ge5ecfe8970-win64-lgpl/bin/ffprobe.exe",
                "output_name": "ffprobe.exe",
            },
        ],
    },
    "deno": {
        "version": "2.8.1",
        "url": "https://github.com/denoland/deno/releases/download/v2.8.1/deno-x86_64-pc-windows-msvc.zip",
        "sha256": "5fb5bac71f609fb91ec8960fb290885aadc27eeb22f07a8eca0c3db6be38b11a",
        "upstream": "https://github.com/denoland/deno",
        "license": "MIT",
        "license_file": "tools/licenses/Deno-MIT.txt",
        "archive_members": [
            {
                "path": "deno.exe",
                "output_name": "deno.exe",
            },
        ],
    },
}
EXPECTED_LICENSES = {
    "Deno-MIT.txt",
    "FFmpeg-LGPL-2.1.txt",
    "LAME-LGPL-2.0.txt",
    "QuickJS-MIT.txt",
}


def load_script(name, path):
    if not Path(path).is_file():
        raise AssertionError(f"required script is missing: {path}")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_pe(path, machine=0x8664):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = bytearray(0x90)
    data[:2] = b"MZ"
    data[0x3C:0x40] = (0x80).to_bytes(4, "little")
    data[0x80:0x84] = b"PE\0\0"
    data[0x84:0x86] = machine.to_bytes(2, "little")
    path.write_bytes(data)


def create_valid_package(parent):
    package_root = Path(parent) / PACKAGE_NAME
    write_pe(package_root / APP_EXE)
    for helper in ("ffmpeg.exe", "ffprobe.exe", "deno.exe"):
        write_pe(package_root / "Helpers" / helper)
    (package_root / "THIRD_PARTY_NOTICES.txt").write_text("notices", encoding="utf-8")
    (package_root / "README-Windows.txt").write_text("readme", encoding="utf-8")
    for license_name in EXPECTED_LICENSES:
        license_path = package_root / "tools" / "licenses" / license_name
        license_path.parent.mkdir(parents=True, exist_ok=True)
        license_path.write_text("license", encoding="utf-8")
    return package_root


def write_zip(path, members):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for member, content in members.items():
            archive.writestr(member, content)


def raw_ico_entries(path):
    data = Path(path).read_bytes()
    if len(data) < 6:
        raise AssertionError("truncated ICONDIR")
    reserved, image_type, count = struct.unpack_from("<HHH", data, 0)
    if (reserved, image_type) != (0, 1):
        raise AssertionError(f"invalid ICONDIR: {(reserved, image_type)}")
    if len(data) < 6 + (16 * count):
        raise AssertionError("truncated ICONDIRENTRY table")

    entries = []
    for index in range(count):
        fields = struct.unpack_from("<BBBBHHII", data, 6 + (16 * index))
        width, height, _colors, entry_reserved, planes, bits, length, offset = fields
        if entry_reserved != 0 or planes != 1 or bits != 32:
            raise AssertionError(f"invalid ICONDIRENTRY metadata: {fields}")
        payload = data[offset:offset + length]
        if len(payload) != length or payload[:8] != b"\x89PNG\r\n\x1a\n":
            raise AssertionError("ICO frame is not a complete PNG payload")
        ihdr_length = struct.unpack_from(">I", payload, 8)[0]
        if payload[12:16] != b"IHDR" or ihdr_length != 13:
            raise AssertionError("PNG payload does not begin with IHDR")
        png_width, png_height = struct.unpack_from(">II", payload, 16)
        entries.append(
            {
                "advertised": (width or 256, height or 256),
                "payload": (png_width, png_height),
            }
        )
    return entries


def archive_package(package_root, archive_path):
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in package_root.rglob("*"):
            if path.is_file():
                archive.write(path, path.relative_to(package_root.parent).as_posix())


class WindowsBuildScriptTests(unittest.TestCase):
    def test_package_checker_requires_referenced_license_texts(self):
        checker = load_script("check_windows_package_licenses", PACKAGE_CHECKER)
        with tempfile.TemporaryDirectory() as tmpdir:
            package_root = create_valid_package(tmpdir)
            (package_root / "tools" / "licenses" / "Deno-MIT.txt").unlink()

            result = checker.check_package(package_root)

        self.assertTrue(
            any("Deno-MIT.txt" in error for error in result.errors),
            result.errors,
        )

    def test_build_script_copies_the_referenced_license_directory(self):
        content = BUILD_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('Copy-Item -Recurse "tools/licenses"', content)

    def test_windows_tool_manifest_is_immutable_and_complete(self):
        self.assertTrue(MANIFEST.is_file(), "Windows helper manifest is missing")
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))

        self.assertEqual(manifest, EXPECTED_MANIFEST)

    def test_package_checker_requires_exact_helper_names(self):
        self.assertTrue(PACKAGE_CHECKER.is_file(), "Windows package checker is missing")
        checker = load_script("check_windows_package", PACKAGE_CHECKER)
        with tempfile.TemporaryDirectory() as tmpdir:
            result = checker.check_package(Path(tmpdir))

        for helper in ("ffmpeg.exe", "ffprobe.exe", "deno.exe"):
            self.assertTrue(
                any(helper in error for error in result.errors),
                f"missing diagnostic for {helper}: {result.errors}",
            )

    def test_package_checker_accepts_complete_static_amd64_fixture(self):
        checker = load_script("check_windows_package_valid", PACKAGE_CHECKER)
        with tempfile.TemporaryDirectory() as tmpdir:
            package_root = create_valid_package(tmpdir)

            result = checker.check_package(package_root)

        self.assertTrue(result.ok, result.errors)

    def test_package_checker_accepts_an_explicit_legacy_package_name(self):
        checker = load_script("check_windows_package_legacy", PACKAGE_CHECKER)
        legacy_name = "YT-Downloader-Pro-v1.8.7-Windows-x64"
        with tempfile.TemporaryDirectory() as tmpdir:
            package_root = create_valid_package(tmpdir)
            legacy_root = package_root.with_name(legacy_name)
            package_root.rename(legacy_root)

            result = checker.check_package(legacy_root, package_name=legacy_name)

        self.assertTrue(result.ok, result.errors)

    def test_package_checker_rejects_duplicate_and_wrong_architecture_helpers(self):
        checker = load_script("check_windows_package_invalid", PACKAGE_CHECKER)
        with tempfile.TemporaryDirectory() as tmpdir:
            package_root = create_valid_package(tmpdir)
            write_pe(package_root / "_internal" / "FFMPEG.EXE")
            write_pe(package_root / "Helpers" / "deno.exe", machine=0xAA64)

            result = checker.check_package(package_root)

        self.assertTrue(any("duplicate" in error and "ffmpeg.exe" in error.lower() for error in result.errors))
        self.assertTrue(any("AMD64" in error and "deno.exe" in error for error in result.errors))

    def test_package_checker_requires_exact_zip_name_and_single_consistent_top_level(self):
        checker = load_script("check_windows_package_zip", PACKAGE_CHECKER)
        with tempfile.TemporaryDirectory() as tmpdir:
            package_root = create_valid_package(tmpdir)
            archive_path = Path(tmpdir) / f"{PACKAGE_NAME}.zip"
            archive_package(package_root, archive_path)

            valid = checker.check_package(archive_path)
            wrong_name = Path(tmpdir) / "renamed.zip"
            archive_path.rename(wrong_name)
            invalid = checker.check_package(wrong_name)

        self.assertTrue(valid.ok, valid.errors)
        self.assertTrue(any(PACKAGE_NAME in error for error in invalid.errors))

    def test_package_checker_rejects_duplicate_archive_paths(self):
        checker = load_script("check_windows_package_duplicate_zip", PACKAGE_CHECKER)
        with tempfile.TemporaryDirectory() as tmpdir:
            archive_path = Path(tmpdir) / f"{PACKAGE_NAME}.zip"
            duplicate = f"{PACKAGE_NAME}/Helpers/ffmpeg.exe"
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr(duplicate, b"first")
                    archive.writestr(duplicate, b"second")

            result = checker.check_package(archive_path)

        self.assertTrue(any("duplicate ZIP member" in error for error in result.errors), result.errors)

    def test_package_checker_rejects_all_unexpected_executables_in_directory(self):
        checker = load_script("check_windows_package_extra_directory_exes", PACKAGE_CHECKER)
        with tempfile.TemporaryDirectory() as tmpdir:
            package_root = create_valid_package(tmpdir)
            write_pe(package_root / "Helpers" / "nested" / "payload.exe")
            write_pe(package_root / "_internal" / "payload.EXE")

            result = checker.check_package(package_root)

        self.assertTrue(any("Helpers/nested/payload.exe" in error for error in result.errors), result.errors)
        self.assertTrue(any("_internal/payload.EXE" in error for error in result.errors), result.errors)

    def test_package_checker_rejects_all_unexpected_executables_in_zip(self):
        checker = load_script("check_windows_package_extra_zip_exes", PACKAGE_CHECKER)
        with tempfile.TemporaryDirectory() as tmpdir:
            package_root = create_valid_package(tmpdir)
            write_pe(package_root / "Helpers" / "nested" / "payload.exe")
            write_pe(package_root / "_internal" / "payload.EXE")
            archive_path = Path(tmpdir) / f"{PACKAGE_NAME}.zip"
            archive_package(package_root, archive_path)

            result = checker.check_package(archive_path)

        self.assertTrue(any("Helpers/nested/payload.exe" in error for error in result.errors), result.errors)
        self.assertTrue(any("_internal/payload.EXE" in error for error in result.errors), result.errors)

    def test_fetcher_hashes_before_opening_archive(self):
        self.assertTrue(TOOL_FETCHER.is_file(), "Windows helper fetcher is missing")
        fetcher = load_script("fetch_windows_tools_hash", TOOL_FETCHER)
        with tempfile.TemporaryDirectory() as tmpdir:
            archive_path = Path(tmpdir) / "not-a-zip.zip"
            archive_path.write_bytes(b"not a zip")
            spec = {
                "sha256": "0" * 64,
                "archive_members": [{"path": "tool.exe", "output_name": "tool.exe"}],
            }

            with self.assertRaisesRegex(ValueError, "SHA-256"):
                fetcher.install_archive(spec, archive_path, Path(tmpdir) / "Helpers")

    def test_fetcher_rejects_zip_traversal_before_copying_declared_members(self):
        fetcher = load_script("fetch_windows_tools_traversal", TOOL_FETCHER)
        with tempfile.TemporaryDirectory() as tmpdir:
            archive_path = Path(tmpdir) / "tool.zip"
            write_zip(archive_path, {"../escape.exe": b"bad", "tool.exe": b"MZ"})
            spec = {
                "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
                "archive_members": [{"path": "tool.exe", "output_name": "tool.exe"}],
            }

            with self.assertRaisesRegex(ValueError, "unsafe ZIP member"):
                fetcher.install_archive(spec, archive_path, Path(tmpdir) / "Helpers")

            self.assertFalse((Path(tmpdir) / "escape.exe").exists())

    def test_fetcher_copies_only_declared_amd64_members(self):
        fetcher = load_script("fetch_windows_tools_members", TOOL_FETCHER)
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir = Path(tmpdir)
            pe_path = tmpdir / "source.exe"
            write_pe(pe_path)
            archive_path = tmpdir / "tool.zip"
            write_zip(archive_path, {"bin/tool.exe": pe_path.read_bytes(), "extra.exe": pe_path.read_bytes()})
            spec = {
                "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
                "archive_members": [{"path": "bin/tool.exe", "output_name": "tool.exe"}],
            }
            output_dir = tmpdir / "Helpers"

            outputs = fetcher.install_archive(spec, archive_path, output_dir)

            self.assertEqual(outputs, [output_dir / "tool.exe"])
            self.assertEqual([path.name for path in output_dir.iterdir()], ["tool.exe"])

    def test_fetcher_tls_context_requires_certificate_and_hostname_verification(self):
        fetcher = load_script("fetch_windows_tools_tls", TOOL_FETCHER)

        context = fetcher.tls_context()

        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)

    def test_fetcher_blocks_https_to_http_to_https_chain_before_plaintext_open(self):
        fetcher = load_script("fetch_windows_tools_redirect", TOOL_FETCHER)

        class ScriptedTransport(request.BaseHandler):
            handler_order = 100

            def __init__(self):
                self.opened = []

            def https_open(self, req):
                return self._open(req)

            def http_open(self, req):
                return self._open(req)

            def _open(self, req):
                self.opened.append(req.full_url)
                headers = Message()
                redirects = {
                    "https://secure.example/start": "http://plain.example/intermediate",
                    "http://plain.example/intermediate": "https://secure.example/final",
                }
                location = redirects.get(req.full_url)
                status = 302 if location else 200
                if location:
                    headers["Location"] = location
                result = response.addinfourl(io.BytesIO(b"archive"), headers, req.full_url, status)
                result.msg = "Found" if location else "OK"
                return result

        transport = ScriptedTransport()
        opener = fetcher.build_https_opener(transport)

        with self.assertRaisesRegex(ValueError, "non-HTTPS redirect"):
            opener.open("https://secure.example/start")

        self.assertEqual(transport.opened, ["https://secure.example/start"])

    def test_icon_generator_writes_all_required_frames(self):
        generator = load_script("generate_windows_icon", ICON_GENERATOR)
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "AppIcon.ico"

            generator.generate_icon(ROOT / "assets" / "AppIcon-1024.png", output)

            entries = raw_ico_entries(output)

        advertised = [entry["advertised"] for entry in entries]
        expected = [(dimension, dimension) for dimension in ICON_DIMENSIONS]
        self.assertEqual(advertised, expected)
        self.assertEqual(len(advertised), len(set(advertised)))
        self.assertEqual(
            [entry["payload"] for entry in entries],
            advertised,
        )
        self.assertEqual(raw_ico_entries(TRACKED_ICON), entries)

    def test_windows_build_is_windowed_onedir_and_preserves_package_root(self):
        self.assertTrue(BUILD_SCRIPT.is_file(), "Windows PowerShell build script is missing")
        script = BUILD_SCRIPT.read_text(encoding="utf-8")

        for argument in (
            "--windowed",
            "--onedir",
            "--icon",
            "--hidden-import",
            "yt_dlp_ejs",
            "--collect-data",
            "--version-file",
        ):
            self.assertIn(argument, script)
        self.assertIn("YT_downloader_188_windows.py", script)
        self.assertIn("Helpers", script)
        self.assertIn("README-Windows.txt", script)
        self.assertIn("THIRD_PARTY_NOTICES.txt", script)
        self.assertIn("Compress-Archive -Path $PackageRoot", script)
        self.assertIn("scripts/check_windows_package.py", script)
        self.assertIn("Set-Content -Path $VersionFile -Encoding ascii", script)
        self.assertIn("--package-name $PackageName", script)

    def test_legacy_windows_build_and_workflow_pass_the_legacy_package_name(self):
        build_script = LEGACY_BUILD_SCRIPT.read_text(encoding="utf-8")
        workflow = LEGACY_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("--package-name $PackageName", build_script)
        self.assertIn('Copy-Item "README-Windows-1.8.7.txt"', build_script)
        self.assertIn("--package-name $packageName", workflow)
        self.assertIn("README-Windows-1.8.7.txt", workflow)

    def test_windowed_exe_self_tests_wait_for_process_exit_and_validate_reports_in_both_invocation_sites(self):
        self.assertTrue(BUILD_SCRIPT.is_file(), "Windows PowerShell build script is missing")
        self.assertTrue(WINDOWS_WORKFLOW.is_file(), "Windows workflow is missing")

        for label, source, executable, report in (
            ("build script", BUILD_SCRIPT.read_text(encoding="utf-8"), "$PackagedExe", "$SelfTestReport"),
            ("workflow", WINDOWS_WORKFLOW.read_text(encoding="utf-8"), "$extractedExe", "$extractedSelfTest"),
        ):
            with self.subTest(label=label):
                self.assertIn("function Invoke-WindowedSelfTest", source)
                self.assertIn("[System.Diagnostics.ProcessStartInfo]", source)
                self.assertIn("$psi.FileName = $ExecutablePath", source)
                self.assertIn("$psi.UseShellExecute = $false", source)
                self.assertIn("$psi.CreateNoWindow = $true", source)
                self.assertIn("$psi.ArgumentList.Add('--self-test')", source)
                self.assertIn("$psi.ArgumentList.Add('--self-test-report')", source)
                self.assertIn("$psi.ArgumentList.Add([string]$ReportPath)", source)
                self.assertIn("[System.Diagnostics.Process]::Start($psi)", source)
                self.assertIn("$null -eq $process", source)
                self.assertIn("$process.WaitForExit()", source)
                self.assertIn("$process.ExitCode", source)
                self.assertIn("$process.Dispose()", source)
                self.assertIn(f"-ExecutablePath {executable} -ReportPath {report}", source)
                self.assertIn("ConvertFrom-Json", source)
                self.assertIn("status -ne 'ok'", source)
                self.assertNotIn("Start-Process", source)
                self.assertNotIn("-ArgumentList", source)


if __name__ == "__main__":
    unittest.main()
