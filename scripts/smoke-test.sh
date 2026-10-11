#!/bin/bash
# Casts Apple's public HLS sample with three test cues through the running Soft Subs app, then
# fetches the rebuilt master playlist, subtitle playlist, a subtitle segment and a proxied playlist.
set -euo pipefail
API=http://127.0.0.1:47800
STREAM=${1:-https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8}

SESSION=$(curl -sf "$API/api/cast" -H 'Content-Type: application/json' -d @- <<EOF | python3 -c 'import json,sys; print(json.load(sys.stdin)["session"])'
{
  "url": "$STREAM",
  "title": "Soft Subs smoke test",
  "startTime": 0,
  "subtitles": {
    "label": "Test English",
    "language": "en",
    "cues": [
      {"start": 1, "end": 4, "text": "Soft Subs: first cue"},
      {"start": 5, "end": 9, "text": "<i>Second cue</i>\nwith two lines"},
      {"start": 61, "end": 64, "text": "Cue in the second segment"}
    ]
  }
}
EOF
)
echo "session: $SESSION"

for _ in $(seq 1 40); do
    PHASE=$(curl -sf "$API/api/status" | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])')
    case "$PHASE" in Lining*|Loading*|Repackaging*) sleep 0.5 ;; *) break ;; esac
done
echo "phase: $PHASE"

ADDR=$(curl -sf "$API/api/status" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lanAddress"])')
BASE="http://$ADDR:47800/s/$SESSION"

echo; echo "== master.m3u8"; curl -sf "$BASE/master.m3u8" | head -20
echo; echo "== subs.m3u8"; curl -sf "$BASE/subs.m3u8" | head -8
echo; echo "== subs/0.vtt"; curl -sf "$BASE/subs/0.vtt"
echo; echo "== subs/1.vtt"; curl -sf "$BASE/subs/1.vtt"
VARIANT=$(curl -sf "$BASE/master.m3u8" | grep -m1 '^/s/')
echo; echo "== first variant (proxied)"; curl -sf "http://$ADDR:47800$VARIANT" | head -8
SEGMENT=$(curl -sf "http://$ADDR:47800$VARIANT" | grep -m1 '^/s/')
echo; echo "== first segment"; curl -sf -o /dev/null -w "HTTP %{http_code}, %{size_download} bytes, %{content_type}\n" "http://$ADDR:47800$SEGMENT"
