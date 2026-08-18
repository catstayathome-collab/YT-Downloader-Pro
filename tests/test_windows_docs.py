import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WINDOWS_README = ROOT / "README-Windows.txt"
LEGACY_WINDOWS_README = ROOT / "README-Windows-1.8.7.txt"
PROJECT_README = ROOT / "README.md"
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
CHECKLIST = ROOT / "docs" / "WINDOWS_TEST_CHECKLIST.md"
MANIFEST = ROOT / "tools" / "windows-tools.json"
RELEASE_GATE = (
    "維護者已完成 macOS 與 Windows 核心下載驗收並核准 `v1.8.8` 公開發布；"
    "其餘情境仍應在後續版本持續回歸。"
)
CHECKLIST_SCENARIOS = (
    "從公開 GitHub Release 下載 ZIP，完成 SHA-256 比對並解壓。",
    "未簽署 SmartScreen 流程顯示；完成來源與 Hash 確認後，透過 `More info` 與 `Run anyway` 啟動。",
    "啟動 `YT Downloader Pro.exe` 時沒有額外命令列視窗。",
    "分析回歸影片 `https://youtu.be/RIItBfZ6S3Q`。",
    "下載並合併最高可用品質 MP4，確認跨過 33.6% 並完成至 100%。",
    "轉換為 192 kbps MP3。",
    "重複下載相同內容時建立 ` (1)`，且不覆寫原檔。",
    "變更輸出資料夾後重新啟動，確認資料夾設定仍被保留。",
    "在可暫停的下載階段測試暫停、繼續與取消行為。",
    "取消下載時，確認既有檔案未被刪除。",
    "確認繁體中文 UI、Windows 字型、檔案對話框與路徑顯示。",
    "分別確認離線、不可寫入資料夾與 helper 遺失時的本地化處理及 log。",
)
WINDOWS_NOTICE_HEADINGS = {
    "ffmpeg": "BtbN FFmpeg and FFprobe (Windows x64 test build)",
    "deno": "Deno (Windows x64 test build)",
}


class WindowsDocumentationTests(unittest.TestCase):
    def test_windows_readme_describes_the_exact_unsigned_release_asset(self):
        text = WINDOWS_README.read_text(encoding="utf-8")

        for expected in (
            "YT-Downloader-Pro-v1.8.8-Windows-x64.zip",
            "YT Downloader Pro.exe",
            "Windows 10 22H2",
            "Windows 11",
            "Intel/AMD x64",
            "%APPDATA%\\YT Downloader Pro\\settings.json",
            "%LOCALAPPDATA%\\YT Downloader Pro\\logs",
            "More info",
            "Run anyway",
            "未簽署版",
            "GitHub Releases",
            "SHA-256",
            "Helpers\\ffmpeg.exe",
            "Helpers\\ffprobe.exe",
            "Helpers\\deno.exe",
        ):
            self.assertIn(expected, text)

        self.assertIn("Windows ARM 不支援", text)
        self.assertIn("不會自動更新內建工具", text)
        self.assertIn("不得下載未獲授權的影音內容", text)

    def test_legacy_windows_readme_keeps_1_8_7_package_identity(self):
        text = LEGACY_WINDOWS_README.read_text(encoding="utf-8")

        self.assertIn("YT Downloader Pro 1.8.7 Windows x64", text)
        self.assertIn("YT-Downloader-Pro-v1.8.7-Windows-x64.zip", text)
        self.assertNotIn("v1.8.8", text)

    def test_project_readme_documents_both_release_assets(self):
        text = PROJECT_README.read_text(encoding="utf-8")

        self.assertIn("Apple Silicon Mac", text)
        self.assertIn("Windows 版", text)
        self.assertIn("YT-Downloader-Pro-v1.8.8-Windows-x64.zip", text)
        self.assertIn("GitHub Release", text)
        self.assertNotIn("尚未附加到公開", text)

    def test_windows_notices_parse_to_the_pinned_tool_manifest(self):
        notices = NOTICES.read_text(encoding="utf-8")
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))

        for tool, expected in manifest.items():
            heading = WINDOWS_NOTICE_HEADINGS[tool]
            section = re.search(
                rf"^## {re.escape(heading)}\n(?P<body>.*?)(?=^## |\Z)",
                notices,
                flags=re.MULTILINE | re.DOTALL,
            )
            self.assertIsNotNone(section, heading)
            body = section.group("body")
            fields = dict(re.findall(r"^- ([^:]+): `?([^`\n]+)`?$", body, flags=re.MULTILINE))

            self.assertEqual(fields["Version"], expected["version"])
            self.assertEqual(fields["Upstream"], expected["upstream"])
            self.assertEqual(fields["Exact archive"], expected["url"])
            self.assertEqual(fields["SHA-256"], expected["sha256"])
            self.assertEqual(fields["License"], expected["license"])
            self.assertEqual(fields["License text"], expected["license_file"])
            mappings = re.findall(
                r"^- Archive member: `([^`]+)` -> `([^`]+)`$",
                body,
                flags=re.MULTILINE,
            )
            self.assertEqual(
                mappings,
                [(member["path"], f"Helpers/{member['output_name']}") for member in expected["archive_members"]],
            )

    def test_windows_acceptance_checklist_has_twelve_unfilled_result_and_note_rows(self):
        text = CHECKLIST.read_text(encoding="utf-8")
        rows = re.findall(r"^\|\s*(\d+)\s*\|\s*(.*?)\s*\|\s*\|\s*\|$", text, flags=re.MULTILINE)

        self.assertEqual(rows, [(str(number), scenario) for number, scenario in enumerate(CHECKLIST_SCENARIOS, start=1)])
        self.assertIn(RELEASE_GATE, text)
        self.assertIn("Windows 11", text)
        self.assertIn("YT-Downloader-Pro-v1.8.8-Windows-x64.zip", text)
        self.assertIn("https://youtu.be/RIItBfZ6S3Q", text)
        self.assertIn("33.6%", text)


if __name__ == "__main__":
    unittest.main()
