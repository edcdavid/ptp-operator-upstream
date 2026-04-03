#!/bin/bash
# entrypoint.sh — Starts the GNSS simulator with self-managed PTY pairs.
#
# gnss-sim creates PTY pairs internally (no socat needed) and symlinks
# the slave side to the paths below. Consumer processes (ts2phc, gpsd,
# test validation) read from these symlinks.
#
# Environment variables:
#   GNSS_SIM_API_PORT  — HTTP API port (default: 9200)
#   GNSS_PTY_TS2PHC   — slave symlink for ts2phc (default: /dev/ttyGNSS_TS2PHC)
#   GNSS_PTY_GNSS0    — slave symlink for gpsd/test (default: /dev/ttyGNSS_GNSS0)

set -euo pipefail

API_PORT="${GNSS_SIM_API_PORT:-9200}"
PTY_TS2PHC="${GNSS_PTY_TS2PHC:-/dev/ttyGNSS_TS2PHC}"
PTY_GNSS0="${GNSS_PTY_GNSS0:-/dev/ttyGNSS_GNSS0}"

echo "Starting GNSS simulator (API port ${API_PORT})"
echo "  PTY links: ${PTY_TS2PHC}, ${PTY_GNSS0}"
exec /usr/local/bin/gnss-sim \
    --pty-links "${PTY_TS2PHC},${PTY_GNSS0}" \
    --api-port "${API_PORT}" \
    "$@"
