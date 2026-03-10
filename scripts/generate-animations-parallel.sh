#!/bin/bash
set -euo pipefail

GEMINI_KEY=$(gcloud secrets versions access latest --secret=orchestrator-gemini-key)
MODEL="veo-3.1-fast-generate-preview"
API_BASE="https://generativelanguage.googleapis.com/v1beta"
GALLERY_DIR="public/images/gallery"
ANIM_DIR="public/images/gallery-animated"
FRAMES_DIR="/tmp/hundhus1_frames"
PROMPT="Subtle gentle motion. The dog breathes naturally, blinks softly, and slightly shifts its head. Ears move gently. Background stays completely still. Soft natural lighting. Seamless loop. No humans."

mkdir -p "$ANIM_DIR" "$FRAMES_DIR"

echo "=== Phase 1: Submit all jobs to Veo 3.1 ==="

declare -A operations

for img in "$GALLERY_DIR"/dog*.jpg; do
  basename=$(basename "$img" .jpg)
  webp_out="$ANIM_DIR/${basename}.webp"

  if [ -f "$webp_out" ]; then
    echo "SKIP $basename (exists)"
    continue
  fi

  echo -n "Submitting $basename... "
  img_b64=$(base64 -i "$img")

  response=$(curl -s -X POST \
    "$API_BASE/models/$MODEL:predictLongRunning?key=$GEMINI_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"instances\": [{
        \"prompt\": \"$PROMPT\",
        \"image\": {
          \"bytesBase64Encoded\": \"$img_b64\",
          \"mimeType\": \"image/jpeg\"
        }
      }],
      \"parameters\": {
        \"sampleCount\": 1,
        \"durationSeconds\": 5
      }
    }")

  op_name=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)

  if [ -n "$op_name" ]; then
    operations[$basename]="$op_name"
    echo "OK ($op_name)"
  else
    error=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',{}).get('message','?'))" 2>/dev/null)
    echo "FAIL: $error"
  fi

  # Small delay to avoid rate limiting
  sleep 1
done

echo ""
echo "=== Phase 2: Poll and download (${#operations[@]} jobs) ==="

success=0
fail=0
remaining=${#operations[@]}

for attempt in $(seq 1 60); do
  if [ $remaining -eq 0 ]; then break; fi

  sleep 5
  echo "Polling... (attempt $attempt, $remaining remaining)"

  for basename in "${!operations[@]}"; do
    op_name="${operations[$basename]}"
    [ -z "$op_name" ] && continue

    status=$(curl -s "$API_BASE/$op_name?key=$GEMINI_KEY")
    done_val=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('done', False))" 2>/dev/null)

    if [ "$done_val" = "True" ]; then
      error=$(echo "$status" | python3 -c "import sys,json; e=json.load(sys.stdin).get('error',{}); print(e.get('message',''))" 2>/dev/null)

      if [ -n "$error" ]; then
        echo "  FAIL $basename: $error"
        fail=$((fail + 1))
      else
        uri=$(echo "$status" | python3 -c "
import sys,json
data = json.load(sys.stdin)
samples = data.get('response',{}).get('generateVideoResponse',{}).get('generatedSamples',[])
if samples: print(samples[0].get('video',{}).get('uri',''))
" 2>/dev/null)

        if [ -n "$uri" ]; then
          mp4_file="/tmp/${basename}.mp4"
          curl -sL -o "$mp4_file" "${uri}&key=$GEMINI_KEY"

          frame_dir="$FRAMES_DIR/$basename"
          mkdir -p "$frame_dir"
          rm -f "$frame_dir"/*.png

          ffmpeg -y -i "$mp4_file" -t 3 -vf "fps=12,scale=500:500:force_original_aspect_ratio=increase,crop=500:500" "$frame_dir/frame_%04d.png" 2>/dev/null

          webp_out="$ANIM_DIR/${basename}.webp"
          img2webp -d 83 -lossy -q 55 "$frame_dir"/frame_*.png -o "$webp_out"

          size=$(ls -lh "$webp_out" | awk '{print $5}')
          echo "  OK $basename ($size)"
          success=$((success + 1))

          rm -rf "$frame_dir" "$mp4_file"
        else
          echo "  FAIL $basename: no URI"
          fail=$((fail + 1))
        fi
      fi

      operations[$basename]=""
      remaining=$((remaining - 1))
    fi
  done
done

echo ""
echo "=== Done: $success succeeded, $fail failed ==="
