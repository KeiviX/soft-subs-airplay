#!/bin/bash
# Re-sends the last cast request the extension made (saved by the app) and tails the app's log.
set -euo pipefail
LOGS=~/Library/Logs/SoftSubs
curl -s http://127.0.0.1:47800/api/cast -H 'Content-Type: application/json' --data-binary @"$LOGS/last-cast.json"; echo
sleep "${1:-8}"
curl -s http://127.0.0.1:47800/api/status; echo
tail -n 40 "$LOGS/soft-subs.log"
