#!/bin/bash
set -euo pipefail

# Generate animated WebP from gallery images using Veo 3.1
# Usage: ./scripts/generate-animations.sh

GEMINI_KEY=$(gcloud secrets versions access latest --secret=orchestrator-gemini-key)
MODEL="veo-3.1-fast-generate-preview"
API_BASE="https://generativelanguage.googleapis.com/v1beta"
GALLERY_DIR="public/images/gallery"
ANIM_DIR="public/images/gallery-animated"
FRAMES_DIR="/tmp/hundhus1_frames"
PROMPT="Subtle gentle motion. The dog breathes naturally, blinks softly, and slightly shifts its head. Ears move gently. Background stays completely still. Soft natural lighting. Seamless loop. No humans."

mkdir -p "$ANIM_DIR" "$FRAMES_DIR"

generate_one() {
  local img_file="$1"
  local basename=$(basename "$img_file" .jpg)
  local webp_out="$ANIM_DIR/${basename}.webp"

  # Skip if already generated
  if [ -f "$webp_out" ]; then
    echo "SKIP $basename (already exists)"
    return 0
  fi

  echo "SUBMITTING $basename..."
  local img_b64=$(base64 -i "$img_file")

  # Submit to Veo
  local response=$(curl -s -X POST \
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

  local op_name=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)

  if [ -z "$op_name" ]; then
    echo "FAIL $basename: $(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',{}).get('message','Unknown error'))" 2>/dev/null)"
    return 1
  fi

  echo "  Operation: $op_name"

  # Poll for completion (max 3 minutes)
  local attempts=0
  while [ $attempts -lt 36 ]; do
    sleep 5
    local status=$(curl -s "$API_BASE/$op_name?key=$GEMINI_KEY")
    local done=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('done', False))" 2>/dev/null)

    if [ "$done" = "True" ]; then
      # Check for error
      local error=$(echo "$status" | python3 -c "import sys,json; e=json.load(sys.stdin).get('error',{}); print(e.get('message',''))" 2>/dev/null)
      if [ -n "$error" ]; then
        echo "  FAIL $basename: $error"
        return 1
      fi

      # Get download URI
      local uri=$(echo "$status" | python3 -c "
import sys,json
data = json.load(sys.stdin)
samples = data.get('response',{}).get('generateVideoResponse',{}).get('generatedSamples',[])
if samples:
    print(samples[0].get('video',{}).get('uri',''))
" 2>/dev/null)

      if [ -z "$uri" ]; then
        echo "  FAIL $basename: no video URI in response"
        return 1
      fi

      # Download video
      local mp4_file="/tmp/${basename}.mp4"
      curl -sL -o "$mp4_file" "${uri}&key=$GEMINI_KEY"

      # Extract frames and convert to animated WebP
      local frame_dir="$FRAMES_DIR/$basename"
      mkdir -p "$frame_dir"
      rm -f "$frame_dir"/*.png

      ffmpeg -y -i "$mp4_file" -t 3 -vf "fps=12,scale=500:500:force_original_aspect_ratio=increase,crop=500:500" "$frame_dir/frame_%04d.png" 2>/dev/null

      # Create animated WebP (83ms per frame = ~12fps, loop forever)
      img2webp -d 83 -lossy -q 55 "$frame_dir"/frame_*.png -o "$webp_out"

      local size=$(ls -lh "$webp_out" | awk '{print $5}')
      echo "  OK $basename -> $webp_out ($size)"

      # Cleanup
      rm -rf "$frame_dir" "$mp4_file"
      return 0
    fi

    attempts=$((attempts + 1))
  done

  echo "  TIMEOUT $basename"
  return 1
}

# Process all gallery images
echo "=== Generating animated gallery images with Veo 3.1 ==="
echo ""

success=0
fail=0

for img in "$GALLERY_DIR"/dog*.jpg; do
  if generate_one "$img"; then
    success=$((success + 1))
  else
    fail=$((fail + 1))
  fi
  echo ""
done

echo "=== Done: $success succeeded, $fail failed ==="
