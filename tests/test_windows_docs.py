import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WINDOWS_README = ROOT / "README-Windows.txt"
PROJECT_README = ROOT / "README.md"
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
CHECKLIST = ROOT / "docs" / "WINDOWS_TEST_CHECKLIST.md"
MANIFEST = ROOT / "tools" / "windows-tools.json"


class WindowsDocumentationTests(unittest.TestCase):
    def test_windows_readme_describes_the_exact_unsigned_test_artifact(self):
        text = WINDOWS_README.read_text(encoding="utf-8")

        for expected in (
            "YT-Downloader-Pro-v1.8.7-Windows-x64.zip",
            "YT Downloader Pro.exe",
            "Windows 10 22H2",
            "Windows 11",
            "Intel/AMD x64",
            "%APPDATA%\\YT Downloader Pro\\settings.json",
            "%LOCALAPPDATA%\\YT Downloader Pro\\logs",
            "More info",
            "Run anyway",
            "未簽署測試版",
            "GitHub Actions",
            "SHA-256",
            "Helpers\\ffmpeg.exe",
            "Helpers\\ffprobe.exe",
            "Helpers\\deno.exe",
        ):
            self.assertIn(expected, text)

        self.assertIn("Windows ARM 不支援", text)
        self.assertIn("不會自動更新內建工具", text)
        self.assertIn("不得下載未獲授權的影音內容", text)

    def test_project_readme_keeps_macos_release_separate_from_windows_test_build(self):
        text = PROJECT_README.read_text(encoding="utf-8")

        self.assertIn("Apple Silicon Mac", text)
        self.assertIn("Windows 測試版", text)
        self.assertIn("YT-Downloader-Pro-v1.8.7-Windows-x64.zip", text)
        self.assertIn("GitHub Actions artifact", text)
        self.assertIn("尚未附加到公開", text)

    def test_windows_notices_match_the_pinned_tool_manifest(self):
        notices = NOTICES.read_text(encoding="utf-8")
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))

        ffmpeg = manifest["ffmpeg"]
        deno = manifest["deno"]
        for expected in (
            "BtbN",
            ffmpeg["version"],
            ffmpeg["url"],
            ffmpeg["sha256"],
            ffmpeg["license"],
            "Deno",
            "v2.8.1",
            deno["url"],
            deno["sha256"],
            deno["license"],
            deno["license_file"],
        ):
            self.assertIn(expected, notices)

    def test_windows_acceptance_checklist_has_twelve_unfilled_result_and_note_rows(self):
        text = CHECKLIST.read_text(encoding="utf-8")
        rows = re.findall(r"^\|\s*(\d+)\s*\|[^\n]*\|\s*\|\s*\|$", text, flags=re.MULTILINE)

        self.assertEqual(rows, [str(number) for number in range(1, 13)])
        self.assertNotIn("PASS", text.upper())
        self.assertIn("Windows 11", text)
        self.assertIn("YT-Downloader-Pro-v1.8.7-Windows-x64.zip", text)


if __name__ == "__main__":
    unittest.main()
