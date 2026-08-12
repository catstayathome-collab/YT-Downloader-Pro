import tempfile
import unittest
from pathlib import Path

from ytdp.downloader import make_analysis_options, make_download_options
from ytdp.models import DownloadRequest


class DownloadOptionsTests(unittest.TestCase):
    def setUp(self):
        self.request = DownloadRequest(
            url="https://youtu.be/example",
            video_format_id="137",
            audio_format_id="140",
            audio_only=False,
            output_directory="/tmp/downloads",
            title="Title",
        )

    def test_windows_analysis_uses_deno_runtime(self):
        options = make_analysis_options("deno", r"C:\\App\\Helpers\\deno.exe", None)

        self.assertEqual(
            options["js_runtimes"],
            {"deno": {"path": r"C:\\App\\Helpers\\deno.exe"}},
        )
        self.assertNotIn("nocheckcertificate", options)

    def test_analysis_options_add_cookies_only_when_explicitly_enabled(self):
        without_cookies = make_analysis_options("quickjs", "qjs", None)
        with_cookies = make_analysis_options("quickjs", "qjs", ("chrome",))

        self.assertNotIn("cookiesfrombrowser", without_cookies)
        self.assertEqual(with_cookies["cookiesfrombrowser"], ("chrome",))

    def test_video_download_uses_mp4_merge_selector(self):
        options = make_download_options(
            self.request,
            "Title",
            "/tmp/helpers",
            "deno",
            "deno.exe",
            lambda _data: None,
            None,
        )

        self.assertEqual(options["format"], "137+140")
        self.assertEqual(options["merge_output_format"], "mp4")
        self.assertEqual(options["outtmpl"], "/tmp/downloads/Title.mp4")
        self.assertEqual(options["js_runtimes"], {"deno": {"path": "deno.exe"}})
        self.assertNotIn("nocheckcertificate", options)

    def test_mp3_template_has_single_dynamic_extension(self):
        with tempfile.TemporaryDirectory() as directory:
            request = DownloadRequest(
                url="https://youtu.be/example",
                video_format_id=None,
                audio_format_id="140",
                audio_only=True,
                output_directory=directory,
                title="Title",
            )
            options = make_download_options(
                request,
                "Title",
                directory,
                "deno",
                "deno.exe",
                lambda _data: None,
                None,
            )

        self.assertTrue(options["outtmpl"].endswith("Title.%(ext)s"))
        self.assertEqual(options["format"], "140")
        self.assertIsNone(options["merge_output_format"])
        self.assertEqual(
            options["postprocessors"],
            [{
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "192",
            }],
        )

    def test_download_options_add_cookies_only_when_explicitly_enabled(self):
        options = make_download_options(
            self.request,
            "Title",
            "/tmp/helpers",
            "quickjs",
            "qjs",
            lambda _data: None,
            ("firefox",),
        )

        self.assertEqual(options["cookiesfrombrowser"], ("firefox",))


if __name__ == "__main__":
    unittest.main()
