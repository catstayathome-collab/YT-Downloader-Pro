#!/bin/sh
set -eu

root=$(dirname "$0")
mode=$(cat "$root/fixture-mode" 2>/dev/null || true)
last=""
for argument in "$@"; do last="$argument"; done
if printf '%s\n' "$@" | grep -q -- '-show_streams'; then
    name=$(basename "$last")
    printf 'probe:%s\n' "$name" >> "$root/pipeline.trace"
    case "$mode:$name" in
        *unknown-color*:source.mp4) printf '{"streams":[{"index":0,"codec_type":"video","codec_name":"vp9","width":1280,"height":720,"pix_fmt":"yuv420p"}]}'; exit 0 ;;
        *invalid-probe*) printf '{}'; exit 0 ;;
        *wait-source*:source.mp4|*wait-final*:converted.mp4|*wait-capability*:probe-*)
            touch "$root/phase-started"
            trap 'echo stopped >> "$root/pipeline.trace"; exit 0' INT TERM
            while :; do sleep 1; done ;;
    esac
    codec=h264; tag=avc1; width=1280; height=720; duration=10; frames=240
    case "$mode:$name" in
        *convert*:source.mp4|*capability*:source.mp4) codec=vp9 ;;
        *bad-final*:converted.mp4) width=640 ;;
    esac
    case "$name" in
        probe-*) codec=hevc; tag=hvc1; width=3840; height=2160; duration=0.5; frames=12 ;;
        converted.mp4) case "$mode" in *convert*|*capability*) codec=hevc; tag=hvc1 ;; esac ;;
    esac
    case "$mode" in
        *high-resolution*) width=3840; height=2160 ;;
        *original*) codec=vp9 ;;
    esac
    printf '{"streams":[{"index":0,"codec_type":"video","codec_name":"%s","codec_tag_string":"%s","width":%s,"height":%s,"pix_fmt":"yuv420p","color_space":"bt709","color_transfer":"bt709","color_primaries":"bt709","color_range":"tv","duration":"%s","nb_read_frames":"%s"}],"format":{"format_name":"mov,mp4","duration":"%s"}}' "$codec" "$tag" "$width" "$height" "$duration" "$frames" "$duration"
    exit 0
fi
if printf '%s\n' "$@" | grep -q -- '-nostdin'; then
    printf '%s\n' "$*" >> "$root/media-command"
    name=$(basename "$last")
    printf 'encode:%s\n' "$name" >> "$root/pipeline.trace"
    case "$mode:$name" in
        *no-encoder*:probe-*) echo 'Unknown encoder' >&2; exit 1 ;;
        *wait-encode*:converted.mp4)
            printf 'incomplete' > "$last"
            touch "$root/phase-started"
            trap 'echo stopped >> "$root/pipeline.trace"; exit 0' INT TERM
            while :; do sleep 1; done ;;
        *encode-disk-full*:converted.mp4) echo 'No space left on device' >&2; exit 1 ;;
    esac
    printf 'fixture' > "$last"
    printf 'out_time_us=5000000\nprogress=end\n'
    exit 0
fi

template=""
previous=""
for argument in "$@"; do
    if [ "$previous" = "--output" ]; then
        template="$argument"
        break
    fi
    previous="$argument"
done

url=""
for argument in "$@"; do
    url="$argument"
done

if [ -n "$template" ]; then
    base="${template%.%(ext)s}"
    directory=$(dirname "$base")
else
    base="${FAKE_YTDLP_STATE:-/tmp/fake-ytdlp}"
    directory=$(dirname "$base")
fi

state_directory=""
case "$url" in
    *\?state=*) state_directory="${url#*\?state=}" ;;
esac

trace="$root/Example video.fake-trace"
command_log="$root/Example video.fake-command"
printf '%s\n' "$*" >> "$command_log"

if printf '%s\n' "$@" | grep -q -- '--dump-single-json'; then
    if [ -n "$state_directory" ]; then
        printf 'analysis\n' >> "$state_directory/analysis.fake-trace"
    fi
    case "$url" in
        *retry-analysis-wait*)
            : > "$state_directory/analysis-started"
            trap 'exit 0' INT TERM
            sleep 2
            printf '%s\n' '{"id":"fake","title":"Fake","webpage_url":"https://fake.test/video","formats":[{"format_id":"137","url":"https://media.test/137","vcodec":"avc1","acodec":"none","ext":"mp4"},{"format_id":"140","url":"https://media.test/140","vcodec":"none","acodec":"mp4a","ext":"m4a"}]}'
            ;;
        *missing-format*)
            printf '%s\n' '{"id":"fake","title":"Fake","webpage_url":"https://fake.test/video","formats":[{"format_id":"140","url":"https://media.test/140","vcodec":"none","acodec":"mp4a","ext":"m4a"}]}'
            ;;
        *)
            printf '%s\n' '{"id":"fake","title":"Fake","webpage_url":"https://fake.test/video","formats":[{"format_id":"137","url":"https://media.test/137","vcodec":"avc1","acodec":"none","ext":"mp4"},{"format_id":"140","url":"https://media.test/140","vcodec":"none","acodec":"mp4a","ext":"m4a"}]}'
            ;;
    esac
    exit 0
fi

printf 'download\n' >> "$trace"

case "$url" in
    *success*)
        printf 'ytdp:phase|downloading\n'
        printf 'ytdp:progress|50%%|50|100|10|5\n'
        : > "$base.mp4.part"
        printf 'ytdp:phase|merging\n' >&2
        printf 'fixture' > "$base.mp4"
        if [ -f "$root/real-source.mp4" ]; then
            cp "$root/real-source.mp4" "$base.mp4"
            cp "$root/fixture.srt" "$base.ja.srt"
        fi
        rm -f "$base.mp4.part"
        printf 'ytdp:filepath|%s.mp4\n' "$base"
        ;;
    *no-final*)
        printf 'ytdp:phase|downloading\n'
        ;;
    *pause*|*consumer-cancel*)
        printf 'ytdp:phase|downloading\n'
        : > "$base.mp4.part"
        trap 'exit 0' INT TERM
        while :; do sleep 1; done
        ;;
    *merge-ignore-int*)
        printf 'ytdp:phase|downloading\n'
        : > "$base.f137.mp4.part"
        printf 'ytdp:phase|merging\n' >&2
        : > "$base.mp4"
        trap '' INT
        trap 'exit 0' TERM
        while :; do sleep 1; done
        ;;
    *ignore-int*)
        printf 'ytdp:phase|downloading\n'
        : > "$base.mp4.part"
        trap '' INT
        trap 'exit 0' TERM
        while :; do sleep 1; done
        ;;
    *merge*)
        printf 'ytdp:phase|downloading\n'
        : > "$base.f137.mp4.part"
        printf 'ytdp:phase|merging\n' >&2
        : > "$base.mp4"
        trap 'exit 0' INT TERM
        while :; do sleep 1; done
        ;;
    *postprocess-error*)
        printf 'ytdp:phase|postprocessing\n' >&2
        printf 'conversion failed\n' >&2
        exit 1
        ;;
    *postprocess*)
        printf 'ytdp:phase|downloading\n'
        : > "$base.mp4.part"
        printf 'ytdp:phase|postprocessing\n' >&2
        trap 'exit 0' INT TERM
        while :; do sleep 1; done
        ;;
    *cancel*)
        printf 'ytdp:phase|downloading\n'
        : > "$base.mp4.part"
        : > "$base.f137.mp4"
        : > "$base.f137.mp4.part-Frag1"
        : > "$base.f137.mp4.ytdl"
        : > "$root/Example video.f137.mp4.part-FragNotANumber"
        : > "$root/Example video2.f137.mp4.part-Frag1"
        : > "$base.mp4"
        : > "$root/Example video.mp4"
        : > "$root/Foreign.mp4.part"
        trap 'exit 0' INT TERM
        while :; do sleep 1; done
        ;;
    *retry-403*|*missing-format*|*retry-analysis-wait*)
        attempts="$base.fake-download-attempts"
        count=0
        if [ -f "$attempts" ]; then count=$(cat "$attempts"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$attempts"
        if [ "$count" -eq 1 ]; then
            printf 'HTTP Error 403: Forbidden\n' >&2
            exit 1
        fi
        printf 'ytdp:phase|downloading\n'
        printf 'fixture' > "$base.mp4"
        printf 'ytdp:filepath|%s.mp4\n' "$base"
        ;;
    *arbitrary-error*)
        printf 'converter explosion\n' >&2
        exit 1
        ;;
    *permission-error*)
        printf 'Operation not permitted while writing output\n' >&2
        exit 1
        ;;
    *disk-full*)
        printf 'No space left on device\n' >&2
        exit 1
        ;;
    *)
        printf 'unknown fixture mode\n' >&2
        exit 2
        ;;
esac
