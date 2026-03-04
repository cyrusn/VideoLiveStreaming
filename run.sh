#!/bin/bash

set -e

# =========================================================
# CONFIG
# =========================================================

RECORD_ENABLED=false        # set true to enable MP4 recording
RETENTION_DAYS=7            # only applies if RECORD_ENABLED=true
STATUS_INTERVAL=5           # seconds between status prints


RTMP_PORT=1935
HTTP_PORT=2510

# =========================================================
# PATHS
# =========================================================

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
PUBLIC_DIR="$BASE_DIR/public"
HLS_DIR="$PUBLIC_DIR/hls"
REC_DIR="$BASE_DIR/recordings"

# Ensure directories exist
mkdir -p "$HLS_DIR" "$REC_DIR"

# Validate STATUS_INTERVAL
if ! [[ "$STATUS_INTERVAL" =~ ^[0-9]+$ ]]; then
    STATUS_INTERVAL=5
fi

# Timestamped recording file (only used if enabled)
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RECORD_FILE="$REC_DIR/stream_$TIMESTAMP.mp4"

# =========================================================
# CLEANUP OLD FILES
# =========================================================

echo "🧹 Clearing old HLS segments..."
# Only clear on initial startup to avoid 404s during brief disconnects
rm -f "$HLS_DIR"/*.ts "$HLS_DIR"/*.m3u8 2>/dev/null || true

if [[ "$RECORD_ENABLED" == true ]]; then
    echo "🧹 Cleaning recordings older than $RETENTION_DAYS days..."
    find "$REC_DIR" -type f -name "*.mp4" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
fi

# =========================================================
# SHUTDOWN HANDLER
# =========================================================

cleanup() {
    echo ""
    echo "⏹ Stopping server..."
    if [ -n "$CADDY_PID" ]; then
        kill "$CADDY_PID" 2>/dev/null || true
    fi
    if [ -n "$FFMPEG_PID" ]; then
        pkill -P "$FFMPEG_PID" 2>/dev/null || true
        kill "$FFMPEG_PID" 2>/dev/null || true
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM

# =========================================================
# START FFMPEG (RTMP → HLS [+ optional MP4])
# =========================================================

echo "▶ Starting FFmpeg (waiting for OBS)..."

while true; do
    echo "⏳ Waiting for OBS connection..."

    # NOTE: We do NOT clean HLS folder here to avoid "empty folder" issues 
    # while waiting for the next connection. Old files remain until overwritten.

    FFMPEG_CMD=(
        ffmpeg -y -loglevel warning
        -rtmp_live live
        -rtmp_listen 1
        -i "rtmp://0.0.0.0:${RTMP_PORT}/live"
        -map 0:v -map 0:a
        -c:v copy
        -c:a aac
        -f hls
        -hls_time 2
        -hls_list_size 10
        -hls_flags delete_segments+append_list+temp_file
        "$HLS_DIR/stream.m3u8"
    )

    if [[ "$RECORD_ENABLED" == true ]]; then
        TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
        RECORD_FILE="$REC_DIR/stream_$TIMESTAMP.mp4"
        FFMPEG_CMD+=(
            -map 0:v -map 0:a
            -c:v copy
            -c:a aac
            -movflags +faststart
            "$RECORD_FILE"
        )
    fi

    "${FFMPEG_CMD[@]}"

    echo "⚠ OBS disconnected. Restarting FFmpeg in 2 seconds..."
    sleep 2
done &

FFMPEG_PID=$!

# =========================================================
# WAIT FOR RTMP PORT (OBS CONNECT FIX)
# =========================================================

echo "⏳ Waiting for RTMP port ${RTMP_PORT}..."
while ! lsof -i :${RTMP_PORT} >/dev/null 2>&1; do
    sleep 1
done

# =========================================================
# START CADDY (INLINE CONFIG, RELATIVE ROOT)
# =========================================================

echo "▶ Starting Caddy..."

(
    cd "$BASE_DIR"
    exec caddy run --adapter caddyfile --config - <<EOF
:${HTTP_PORT} {
    root * public
    file_server
    log {
        level ERROR
    }
}
EOF
) &

CADDY_PID=$!

# =========================================================
# STATUS LOOP
# =========================================================

echo ""
echo "✅ Server running"
echo "OBS Server : rtmp://localhost:${RTMP_PORT}/live"
echo "OBS Key    : stream"
echo "Live URL   : http://localhost:${HTTP_PORT}/"

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
