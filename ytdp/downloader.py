"""Shared yt-dlp option builders for supported desktop platforms."""

import os


def _add_runtime_and_cookies(options, js_runtime_name, js_runtime_path, cookies_browser):
    if js_runtime_name and js_runtime_path:
        options["js_runtimes"] = {js_runtime_name: {"path": js_runtime_path}}
    if cookies_browser:
        options["cookiesfrombrowser"] = cookies_browser
    return options


def make_analysis_options(js_runtime_name, js_runtime_path, cookies_browser):
    """Return safe yt-dlp options for video analysis."""
    return _add_runtime_and_cookies(
        {"quiet": True}, js_runtime_name, js_runtime_path, cookies_browser
    )


def make_download_options(
    request,
    output_stem,
    ffmpeg_dir,
    js_runtime_name,
    js_runtime_path,
    progress_hook,
    cookies_browser,
):
    """Return safe yt-dlp options for one download request."""
    output_template = (
        f"{output_stem}.%(ext)s" if request.audio_only else f"{output_stem}.mp4"
    )
    options = {
        "ffmpeg_location": ffmpeg_dir,
        "outtmpl": os.path.join(request.output_directory, output_template),
        "progress_hooks": [progress_hook],
        "format": (
            request.audio_format_id or "bestaudio/best"
            if request.audio_only
            else f"{request.video_format_id}+{request.audio_format_id}"
        ),
        "merge_output_format": None if request.audio_only else "mp4",
    }
    _add_runtime_and_cookies(
        options, js_runtime_name, js_runtime_path, cookies_browser
    )
    if request.audio_only:
        options["postprocessors"] = [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "mp3",
            "preferredquality": "192",
        }]
    return options
