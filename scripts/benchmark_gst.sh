#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------
BENCH_ITERATIONS=${BENCH_ITERATIONS:-20}
BENCH_FRAMES=${BENCH_FRAMES:-1800}        # 60s at 30 fps
BENCH_WIDTH=${BENCH_WIDTH:-1920}
BENCH_HEIGHT=${BENCH_HEIGHT:-1080}
BENCH_FRAMERATE=${BENCH_FRAMERATE:-30}
BENCH_BITRATE=${BENCH_BITRATE:-100000}    # kbps — 100 Mbps default
BENCH_FILE=${BENCH_FILE:-/dev/shm/benchmark_test.h264}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[benchmark] $*" >&2; }

generate_test_stream() {
    if [ -f "$BENCH_FILE" ]; then
        log "Reusing existing test stream: $BENCH_FILE"
        return
    fi
    log "Generating ${BENCH_WIDTH}x${BENCH_HEIGHT}@${BENCH_FRAMERATE}fps " \
        "${BENCH_BITRATE}kbps H264 stream (${BENCH_FRAMES} frames)..."
    gst-launch-1.0 -e -q \
        videotestsrc num-buffers="$BENCH_FRAMES" pattern=smpte ! \
        "video/x-raw,width=$BENCH_WIDTH,height=$BENCH_HEIGHT,framerate=$BENCH_FRAMERATE/1" ! \
        x264enc speed-preset=ultrafast tune=zerolatency \
            bitrate="$BENCH_BITRATE" key-int-max=30 ! \
        "video/x-h264,profile=constrained-baseline" ! \
        filesink location="$BENCH_FILE"
    log "Test stream ready: $(du -h "$BENCH_FILE" | cut -f1)"
}

# Run a pipeline once; print "user_s sys_s real_s" to stdout.
time_pipeline() {
    local output
    output=$( TIMEFORMAT='%U %S %R'; { time gst-launch-1.0 -q -e "$@" ; } 2>&1 )
    echo "$output" | tail -1
}

# Run a scenario N times, print summary to stderr and CSV rows to stdout.
run_scenario() {
    local name=$1; shift
    local desc=$1; shift

    log ""
    log "=== $name ==="
    log "$desc"
    log "Iterations: $BENCH_ITERATIONS"

    local user_vals=() sys_vals=() real_vals=()

    for i in $(seq 1 "$BENCH_ITERATIONS"); do
        read -r u s r <<< "$(time_pipeline "$@")"
        user_vals+=("$u"); sys_vals+=("$s"); real_vals+=("$r")
        log "  run $i/$BENCH_ITERATIONS  user=${u}s  sys=${s}s  real=${r}s"
    done

    read -r u_mean u_std s_mean s_std r_mean r_std cpu_mean cpu_std <<< "$(python3 -c "
import statistics as st
u = [float(x) for x in '${user_vals[*]}'.split()]
s = [float(x) for x in '${sys_vals[*]}'.split()]
r = [float(x) for x in '${real_vals[*]}'.split()]
cpu = [a+b for a,b in zip(u,s)]
def fmt(vals):
    m = st.mean(vals)
    sd = st.pstdev(vals) if len(vals) > 1 else 0.0
    return f'{m:.4f} {sd:.4f}'
print(fmt(u), fmt(s), fmt(r), fmt(cpu))
")"

    log "  ---- Summary ($name) ----"
    log "  User CPU:   ${u_mean}s  (±${u_std}s)"
    log "  System CPU: ${s_mean}s  (±${s_std}s)"
    log "  Total CPU:  ${cpu_mean}s  (±${cpu_std}s)"
    log "  Wall clock: ${r_mean}s  (±${r_std}s)"

    for i in $(seq 0 $(( BENCH_ITERATIONS - 1 ))); do
        echo "$name,${user_vals[$i]},${sys_vals[$i]},${real_vals[$i]}"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "GStreamer H264 Pipeline Benchmark"
log "gst-launch-1.0 version: $(gst-launch-1.0 --version | head -1)"
log "Architecture: $(uname -m)"
log "Config: ${BENCH_WIDTH}x${BENCH_HEIGHT}@${BENCH_FRAMERATE}fps, ${BENCH_BITRATE}kbps, ${BENCH_FRAMES} frames"
log "Iterations per scenario: $BENCH_ITERATIONS"
log ""

generate_test_stream

echo "scenario,user_cpu_s,sys_cpu_s,wall_s"

# Scenario A: H264 passthrough (framework overhead)
run_scenario "passthrough" \
    "filesrc ! h264parse ! rtph264pay ! rtph264depay ! h264parse ! rtph264pay ! fakesink" \
    filesrc location="$BENCH_FILE" ! \
    h264parse ! \
    rtph264pay config-interval=-1 ! \
    rtph264depay ! \
    h264parse ! \
    rtph264pay config-interval=-1 ! \
    fakesink

# Scenario B: full pipeline structure without SRTP
run_scenario "full_pipeline" \
    "filesrc ! h264parse ! capsfilter ! queue ! rtph264pay ! rtph264depay ! h264parse ! capsfilter ! rtph264pay ! tee ! queue ! fakesink" \
    filesrc location="$BENCH_FILE" ! \
    h264parse ! \
    "video/x-h264,stream-format=byte-stream" ! \
    capsfilter ! queue ! \
    rtph264pay config-interval=-1 ! \
    rtph264depay ! \
    h264parse ! \
    "video/x-h264,stream-format=byte-stream" ! \
    capsfilter ! \
    rtph264pay config-interval=-1 ! \
    tee ! queue ! \
    fakesink

# Scenario C: full pipeline + SRTP encryption
run_scenario "full_pipeline_srtp" \
    "filesrc ! h264parse ! capsfilter ! queue ! rtph264pay ! rtph264depay ! h264parse ! capsfilter ! rtph264pay ! tee ! queue ! srtpenc ! fakesink" \
    filesrc location="$BENCH_FILE" ! \
    h264parse ! \
    "video/x-h264,stream-format=byte-stream" ! \
    capsfilter ! queue ! \
    rtph264pay config-interval=-1 ! \
    rtph264depay ! \
    h264parse ! \
    "video/x-h264,stream-format=byte-stream" ! \
    capsfilter ! \
    rtph264pay config-interval=-1 ! \
    "application/x-rtp,payload=(int)96,ssrc=(uint)1234" ! \
    tee ! queue ! \
    srtpenc random-key=true rtp-cipher=aes-128-icm rtp-auth=hmac-sha1-80 ! \
    fakesink

rm -f "$BENCH_FILE"
log ""
log "Done."
