#!/bin/bash

set -e

# =========================
# CONFIGURATION
# =========================

# Keep recordings for N days
RETENTION_DAYS=7

# Status update interval (seconds)
STATUS_INTERVAL=5

# Upload command (leave empty to disable)
# Examples:
# UPLOAD_CMD="scp \"$RECORD_FILE\" user@server:/path/"
# UPLOAD_CMD="aws s3 cp \"$RECORD_FILE\" s3://bucket/path/"
# UPLOAD_CMD="rclone copy \"$RECORD_FILE\" remote:path/"
UPLOAD_CMD=""

# =========================
# PATHS
# =========================

# Base directory = directory of this script
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

HLS_DIR="$BASE_DIR/hls"
REC_DIR="$BASE_DIR/hls"

RTMP_PORT=1935
HTTP_PORT=8080

mkdir -p "$HLS_DIR" "$REC_DIR"

# Validate STATUS_INTERVAL
if ! [[ "$STATUS_INTERVAL" =~ ^[0-9]+$ ]]; then
    echo "⚠ STATUS_INTERVAL invalid, defaulting to 5 seconds"
    STATUS_INTERVAL=5
fi

# Timestamped recording file
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RECORD_FILE="$REC_DIR/stream_$TIMESTAMP.mp4"

# =========================
# CLEAN OLD RECORDINGS
# =========================

echo "🧹 Cleaning recordings older than $RETENTION_DAYS days..."
find "$REC_DIR" -type f -name "*.mp4" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true

# =========================
# CLEANUP HANDLER
# =========================

cleanup() {
    echo ""
    echo "⏹ Stopping server..."

    pkill -P $$ 2>/dev/null || true
    wait 2>/dev/null || true

    if [[ -n "$UPLOAD_CMD" && -f "$RECORD_FILE" ]]; then
        echo "☁ Uploading recording..."
        eval "$UPLOAD_CMD"
        echo "✅ Upload completed"
    fi

    exit 0
}

trap cleanup SIGINT SIGTERM

# =========================
# START FFMPEG
# =========================

echo "▶ Starting FFmpeg (Live + Recording)..."
ffmpeg -y -loglevel warning \
    -listen 1 \
    -i rtmp://0.0.0.0:${RTMP_PORT}/live \
    -map 0:v -map 0:a \
    -c:v copy \
    -c:a aac \
    -f hls \
    -hls_time 4 \
    -hls_list_size 5 \
    -hls_flags delete_segments+append_list \
    "$HLS_DIR/stream.m3u8" \
    -map 0:v -map 0:a \
    -c:v copy \
    -c:a aac \
    -movflags +faststart \
    "$RECORD_FILE" &

FFMPEG_PID=$!

sleep 2

# =========================
# START CADDY
# =========================

echo "▶ Starting Caddy..."
cd "$BASE_DIR"
caddy run --config Caddyfile --adapter caddyfile &
CADDY_PID=$!

# =========================
# STATUS DISPLAY
# =========================

echo ""
echo "✅ Streaming started"
echo "OBS Server : rtmp://localhost:${RTMP_PORT}/live"
echo "OBS Key    : stream"
echo "Live URL   : http://localhost:${HTTP_PORT}/hls/stream.m3u8"
echo "Recording : $RECORD_FILE"
echo ""
echo "Press Ctrl+C to stop"
echo ""

while kill -0 "$FFMPEG_PID" 2>/dev/null; do
    if [[ -f "$RECORD_FILE" ]]; then
        SIZE=$(du -h "$RECORD_FILE" | awk '{print $1}')
        DURATION=$(ffprobe -v error \
            -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 \
            "$RECORD_FILE" 2>/dev/null | awk '{printf "%02d:%02d:%02d\n",$1/3600,($1%3600)/60,$1%60}')
        echo "⏺ Recording... Size: $SIZE | Duration: $DURATION"
    fi
    sleep "${STATUS_INTERVAL:-5}"
done

wait
