#!/bin/bash

set -e

# =========================
# CONFIG
# =========================

RECORD_ENABLED=false        # ✅ default: no recording
RETENTION_DAYS=7
STATUS_INTERVAL=5

RTMP_PORT=1935
HTTP_PORT=8080

# =========================
# PATHS
# =========================

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
HLS_DIR="$BASE_DIR/hls"
REC_DIR="$BASE_DIR/recordings"

mkdir -p "$HLS_DIR" "$REC_DIR"

# Validate sleep interval
if ! [[ "$STATUS_INTERVAL" =~ ^[0-9]+$ ]]; then
    STATUS_INTERVAL=5
fi

# Timestamped recording file (only used if enabled)
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RECORD_FILE="$REC_DIR/stream_$TIMESTAMP.mp4"

# =========================
# CLEAN OLD RECORDINGS
# =========================

if [[ "$RECORD_ENABLED" == true ]]; then
    find "$REC_DIR" -type f -name "*.mp4" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
fi

# =========================
# CLEANUP
# =========================

cleanup() {
    echo ""
    echo "⏹ Stopping server..."
    pkill -P $$ 2>/dev/null || true
    wait 2>/dev/null || true
    exit 0
}

trap cleanup SIGINT SIGTERM

# =========================
# BUILD FFMPEG COMMAND
# =========================

echo "▶ Starting FFmpeg (Live streaming)..."

FFMPEG_CMD=(
    ffmpeg -y -loglevel warning
    -listen 1
    -i "rtmp://0.0.0.0:${RTMP_PORT}/live"
    -map 0:v -map 0:a
    -c:v copy
    -c:a aac
    -f hls
    -hls_time 4
    -hls_list_size 5
    -hls_flags delete_segments+append_list
    "$HLS_DIR/stream.m3u8"
)

# Add recording output only if enabled
if [[ "$RECORD_ENABLED" == true ]]; then
    FFMPEG_CMD+=(
        -map 0:v -map 0:a
        -c:v copy
        -c:a aac
        -movflags +faststart
        "$RECORD_FILE"
    )
fi

# Start FFmpeg
"${FFMPEG_CMD[@]}" &

FFMPEG_PID=$!

sleep 2

# =========================
# START CADDY (INLINE CONFIG)
# =========================

echo "▶ Starting Caddy..."

(
    cd "$BASE_DIR"
    caddy run --adapter caddyfile --config - <<EOF
:8080 {
    root * .
    file_server
    header {
        Cache-Control no-cache
        Access-Control-Allow-Origin *
    }
}
EOF
) &

CADDY_PID=$!

# =========================
# STATUS
# =========================

echo ""
echo "✅ Streaming started"
echo "OBS Server : rtmp://localhost:${RTMP_PORT}/live"
echo "OBS Key    : stream"
echo "Live URL   : http://localhost:${HTTP_PORT}/hls/stream.m3u8"

if [[ "$RECORD_ENABLED" == true ]]; then
    echo "Recording : $RECORD_FILE"
else
    echo "Recording : OFF"
fi

echo ""
echo "Press Ctrl+C to stop"
echo ""

while kill -0 "$FFMPEG_PID" 2>/dev/null; do
    if [[ "$RECORD_ENABLED" == true && -f "$RECORD_FILE" ]]; then
        SIZE=$(du -h "$RECORD_FILE" | awk '{print $1}')
        echo "⏺ Recording... Size: $SIZE"
    fi
    sleep "${STATUS_INTERVAL:-5}"
done

wait
