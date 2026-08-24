#!/bin/sh
set -eu

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

trace="$base.fake-trace"
command_log="$base.fake-command"
printf '%s\n' "$*" >> "$command_log"

if printf '%s\n' "$@" | grep -q -- '--dump-single-json'; then
    printf 'analysis\n' >> "$trace"
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
        printf 'ytdp:phase|merging\n'
        printf 'fixture' > "$base.mp4"
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
        printf 'ytdp:phase|merging\n'
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
        printf 'ytdp:phase|merging\n'
        : > "$base.mp4"
        trap 'exit 0' INT TERM
        while :; do sleep 1; done
        ;;
    *postprocess-error*)
        printf 'ytdp:phase|postprocessing\n'
        printf 'conversion failed\n' >&2
        exit 1
        ;;
    *postprocess*)
        printf 'ytdp:phase|downloading\n'
        : > "$base.mp4.part"
        printf 'ytdp:phase|postprocessing\n'
        trap 'exit 0' INT TERM
        while :; do sleep 1; done
        ;;
    *cancel*)
        printf 'ytdp:phase|downloading\n'
        : > "$base.mp4.part"
        : > "$base.f137.mp4"
        : > "$base.f137.mp4.part-Frag1"
        : > "$base.f137.mp4.ytdl"
        : > "$base.f137.mp4.part-FragNotANumber"
        : > "$directory/Example video2.f137.mp4.part-Frag1"
        : > "$base.mp4"
        : > "$directory/Foreign.mp4.part"
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
        : > "$base.mp4"
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
