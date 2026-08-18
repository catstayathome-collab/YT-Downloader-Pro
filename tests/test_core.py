import tempfile
import unittest
from pathlib import Path

from ytdp.core import format_bytes, reserve_output_stem, sanitize_filename_stem
from ytdp.models import DownloadArtifactTracker, DownloadRequest


class DownloadRequestTests(unittest.TestCase):
    def test_download_request_is_immutable(self):
        request = DownloadRequest(
            url="https://youtu.be/example",
            video_format_id="137",
            audio_format_id="140",
            audio_only=False,
            output_directory="/tmp",
            title="Title",
        )

        with self.assertRaises(AttributeError):
            request.title = "Changed"


class FilenameTests(unittest.TestCase):
    def test_windows_invalid_characters_are_replaced(self):
        self.assertEqual(
            sanitize_filename_stem('A<B>C:D"E/F\\G|H?I*J', "windows"),
            "A_B_C_D_E_F_G_H_I_J",
        )

    def test_windows_control_characters_are_replaced(self):
        self.assertEqual(
            sanitize_filename_stem("A\x00B\x1fC", "windows"),
            "A_B_C",
        )

    def test_windows_trailing_spaces_and_periods_are_removed(self):
        self.assertEqual(sanitize_filename_stem("Video.  ", "windows"), "Video")

    def test_windows_reserved_device_name_is_prefixed(self):
        self.assertEqual(sanitize_filename_stem("CON", "windows"), "_CON")
        self.assertEqual(sanitize_filename_stem("lpt9.notes", "windows"), "_lpt9.notes")

    def test_windows_empty_name_uses_fallback(self):
        self.assertEqual(sanitize_filename_stem("...", "windows"), "download")

    def test_windows_name_is_limited_to_180_characters(self):
        result = sanitize_filename_stem("a" * 250, "windows")

        self.assertEqual(len(result), 180)

    def test_windows_duplicate_allocation_is_case_insensitive(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "Movie.mp4").write_bytes(b"existing")

            result = reserve_output_stem(
                directory,
                "movie",
                ".mp4",
                "windows",
            )

            self.assertEqual(result, "movie (1)")

    def test_windows_duplicate_stem_stays_within_180_characters(self):
        with tempfile.TemporaryDirectory() as directory:
            title = "a" * 180
            Path(directory, f"{title}.mp4").write_bytes(b"existing")

            result = reserve_output_stem(directory, title, ".mp4", "windows")

            self.assertEqual(len(result), 180)
            self.assertTrue(result.endswith(" (1)"))

    def test_windows_intermediate_download_files_reserve_the_entire_stem(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "Movie.webm").write_bytes(b"existing audio")
            Path(directory, "Clip.f137.mp4").write_bytes(b"existing video")

            self.assertEqual(
                reserve_output_stem(directory, "movie", ".mp3", "windows"),
                "movie (1)",
            )
            self.assertEqual(
                reserve_output_stem(directory, "clip", ".mp4", "windows"),
                "clip (1)",
            )

    def test_macos_duplicate_allocation_preserves_existing_behavior(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "Movie.mp4").write_bytes(b"existing")

            result = reserve_output_stem(
                directory,
                "Movie",
                ".mp4",
                "macos",
            )

            self.assertEqual(result, "Movie (1)")


class ArtifactTrackerTests(unittest.TestCase):
    def test_cleanup_removes_only_new_tracked_file(self):
        with tempfile.TemporaryDirectory() as directory:
            existing = Path(directory, "existing.mp4")
            existing.write_bytes(b"keep")
            tracker = DownloadArtifactTracker(directory, "new.mp4")
            partial = Path(directory, "new.mp4.part")
            partial.write_bytes(b"partial")
            tracker.track(partial)

            removed = tracker.cleanup()

            self.assertTrue(existing.exists())
            self.assertFalse(partial.exists())
            self.assertEqual(removed, [str(partial)])


class FormattingTests(unittest.TestCase):
    def test_format_bytes_handles_missing_and_megabytes(self):
        self.assertEqual(format_bytes(None), "--")
        self.assertEqual(format_bytes(1024 * 1024), "1.00 MB")


if __name__ == "__main__":
    unittest.main()
