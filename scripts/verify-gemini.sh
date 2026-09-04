#!/usr/bin/env bash
# End-to-end check of the one path that unit tests cannot cover: does Gemini
# actually come back with diarized speaker labels, and does our parser read
# them?
#
# Synthesises a two-speaker conversation with `say` (two different voices),
# sends it to gemini-3.5-transcribe with diarization on, and reports how many
# distinct speakers came back. Costs a fraction of a cent.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_FILE=.secrets/gemini-key
# Accept the key from the environment, from .env, or from .secrets/gemini-key.
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then
  GEMINI_API_KEY=$(grep -E '^GEMINI_API_KEY=' .env | tail -1 | cut -d= -f2- | tr -d '"'"'"'[:space:]')
fi
KEY="${GEMINI_API_KEY:-$(grep -v '^#' "$KEY_FILE" 2>/dev/null | tr -d '[:space:]' || true)}"
if [ -z "$KEY" ]; then
  echo "No key. Paste one into $KEY_FILE or export GEMINI_API_KEY." >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Building a two-voice test conversation…"
lines=(
  "Samantha|Let's start with the roadmap for next quarter. I want to close on the migration date today."
  "Daniel|I think we should push the migration back a sprint. The latency numbers are the real blocker."
  "Samantha|Agreed. Let's get the latency work scoped this week."
  "Daniel|I can own the scoping document by Friday."
)
i=0
: > "$WORK/list.txt"
for entry in "${lines[@]}"; do
  voice="${entry%%|*}"; text="${entry#*|}"
  say -v "$voice" -o "$WORK/part$i.aiff" "$text"
  echo "file '$WORK/part$i.aiff'" >> "$WORK/list.txt"
  i=$((i+1))
done

# Concatenate, then encode to the same format the app records in.
python3 - "$WORK" <<'PY'
import sys, wave, aifc, subprocess, os
work = sys.argv[1]
parts = sorted(f for f in os.listdir(work) if f.startswith('part') and f.endswith('.aiff'))
subprocess.run(['/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEI16@22050', '-c', '1',
                os.path.join(work, parts[0]), os.path.join(work, 'a0.wav')], check=True)
frames = []
params = None
for idx, p in enumerate(parts):
    wav = os.path.join(work, f'a{idx}.wav')
    if idx:
        subprocess.run(['/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEI16@22050', '-c', '1',
                        os.path.join(work, p), wav], check=True)
    with wave.open(wav) as w:
        params = params or w.getparams()
        frames.append(w.readframes(w.getnframes()))
with wave.open(os.path.join(work, 'joined.wav'), 'wb') as out:
    out.setparams(params)
    for f in frames:
        out.writeframes(f)
print('joined', sum(len(f) for f in frames), 'bytes of PCM')
PY
/usr/bin/afconvert -f m4af -d aac -b 32000 "$WORK/joined.wav" "$WORK/clip.m4a"
BYTES=$(stat -f%z "$WORK/clip.m4a")
echo "clip.m4a: $BYTES bytes"

echo "Uploading…"
START_HEADERS=$(curl -s -D - -o "$WORK/start.json" \
  -X POST "https://generativelanguage.googleapis.com/upload/v1beta/files" \
  -H "x-goog-api-key: $KEY" \
  -H "X-Goog-Upload-Protocol: resumable" \
  -H "X-Goog-Upload-Command: start" \
  -H "X-Goog-Upload-Header-Content-Length: $BYTES" \
  -H "X-Goog-Upload-Header-Content-Type: audio/mp4" \
  -H "Content-Type: application/json" \
  -d '{"file":{"display_name":"scribe-verify"}}')

UPLOAD_URL=$(printf '%s' "$START_HEADERS" | tr -d '\r' | awk 'tolower($1)=="x-goog-upload-url:"{print $2}')
if [ -z "$UPLOAD_URL" ]; then
  echo "Upload did not start:"; cat "$WORK/start.json"; exit 1
fi

FILE_URI=$(curl -s -X POST "$UPLOAD_URL" \
  -H "Content-Length: $BYTES" \
  -H "X-Goog-Upload-Offset: 0" \
  -H "X-Goog-Upload-Command: upload, finalize" \
  --data-binary "@$WORK/clip.m4a" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["file"]["uri"])')
echo "uploaded: $FILE_URI"

echo "Transcribing with diarization…"
curl -s -X POST "https://generativelanguage.googleapis.com/v1beta/interactions" \
  -H "x-goog-api-key: $KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"gemini-3.5-transcribe\",
       \"input\":[{\"type\":\"audio\",\"uri\":\"$FILE_URI\",\"mime_type\":\"audio/mp4\"}],
       \"generation_config\":{\"transcription_config\":{\"mode\":{
         \"type\":\"verbatim\",\"diarization_mode\":\"speaker\",
         \"timestamp_granularities\":[\"word\"]}}}}" > "$WORK/out.json"

python3 scripts/check_diarization.py "$WORK/out.json"
