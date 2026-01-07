#!/bin/bash

set -e

# =========================================================
# CONFIG
# =========================================================

RECORD_ENABLED=false        # set true to enable MP4 recording
RETENTION_DAYS=7            # only applies if RECORD_ENABLED=true
STATUS_INTERVAL=5           # seconds between status prints


RTMP_PORT=1935
HTTP_PORT=8080

# =========================================================
# PATHS
# =========================================================

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
HLS_DIR="$BASE_DIR/hls"
REC_DIR="$BASE_DIR/recordings"

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
    pkill -P $$ 2>/dev/null || true
    wait 2>/dev/null || true
    exit 0
}

trap cleanup SIGINT SIGTERM

# =========================================================
# START FFMPEG (RTMP → HLS [+ optional MP4])
# =========================================================

echo "▶ Starting FFmpeg (waiting for OBS)..."

while true; do
    echo "⏳ Waiting for OBS connection..."

    # Clean HLS on each new session
    rm -f "$HLS_DIR"/*.ts "$HLS_DIR"/*.m3u8 2>/dev/null || true

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
        -hls_list_size 3
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
    caddy run --adapter caddyfile --config - <<EOF
:${HTTP_PORT} {
    root * .
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
