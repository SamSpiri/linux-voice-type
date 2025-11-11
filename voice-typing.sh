#!/usr/bin/env bash
# usage: exec ./voice-typing.sh twice to start and stop recording
# Dependencies: curl, jq, arecord, xdotool, killall

set -euo pipefail
IFS=$'\n\t'

# Configuration
readonly PID_FILE="${HOME}/.local/state/voice-type/record.pid"
readonly FILE="${HOME}/.local/var/voice-type/recording-$(date +%Y%m%d-%H%M%S)"
readonly MAX_DURATION=3600
readonly AUDIO_INPUT='hw:2,0' # Use `arecord -l` to list available devices
source "$HOME/.config/linux-voice-type"      # Ensure this file has restrictive permissions

readonly PREFERRED_FORMATS=(S16_LE S24_LE S24_3LE S32_LE)
readonly PREFERRED_RATES=(48000 44100 16000 32000)
readonly PREFERRED_CHANNELS=(1 2)

detect_default_device() {
  if command -v wpctl &>/dev/null; then
    # PipeWire: just use 'default' (PipeWire will route to current selected source)
    echo "default"
    return
  fi
  if command -v pactl &>/dev/null; then
    # PulseAudio/PipeWire compatibility
    echo "default"
    return
  fi
  # Fallback to first ALSA card
  local card dev
  if arecord -l 2>/dev/null | awk '/card [0-9]+:/ {print; exit}' | \
     sed -E 's/.*card ([0-9]+).*, device ([0-9]+).*/\1 \2/' >/dev/null; then
    read -r card dev < <(arecord -l | awk '/card [0-9]+:/ {print; exit}' | sed -E 's/.*card ([0-9]+).*, device ([0-9]+).*/\1 \2/')
    echo "plughw:${card},${dev}"
    return
  fi
  echo "default"
}

probe_params() {
  local dev="$1"
  local dump
  if ! dump="$(arecord -D "$dev" --dump-hw-params /dev/null 2>&1)"; then
    echo "FORMAT=S16_LE RATE=44100 CHANNELS=1"
    return
  fi
  local formats rates chans
  formats=$(awk '/FORMAT:/ {for(i=2;i<=NF;i++) print $i}' <<<"$dump")
  rates=$(awk '/RATE:/ {for(i=2;i<=NF;i++) print $i}' <<<"$dump")
  chans=$(awk '/CHANNELS:/ {for(i=2;i<=NF;i++) print $i}' <<<"$dump")

  local chosen_format=""
  for f in "${PREFERRED_FORMATS[@]}"; do
    if grep -q "$f" <<<"$formats"; then chosen_format="$f"; break; fi
  done
  [[ -z $chosen_format ]] && chosen_format=$(head -n1 <<<"$formats")

  # Rate lines may be ranges like 8000-48000; pick first preferred inside any range or exact match.
  local chosen_rate=""
  for r in "${PREFERRED_RATES[@]}"; do
    if grep -qw "$r" <<<"$rates"; then chosen_rate="$r"; break
    elif grep -Eq "([0-9]+)-([0-9]+)" <<<"$rates"; then
      local lo hi
      lo=$(grep -Eo '([0-9]+)-([0-9]+)' <<<"$rates" | head -n1 | cut -d- -f1)
      hi=$(grep -Eo '([0-9]+)-([0-9]+)' <<<"$rates" | head -n1 | cut -d- -f2)
      if (( r >= lo && r <= hi )); then chosen_rate="$r"; break; fi
    fi
  done
  [[ -z $chosen_rate ]] && chosen_rate=$(grep -Eo '^[0-9]+' <<<"$rates" | head -n1 || echo 44100)

  local chosen_channels=""
  for c in "${PREFERRED_CHANNELS[@]}"; do
    if grep -qw "$c" <<<"$chans"; then chosen_channels="$c"; break; fi
  done
  [[ -z $chosen_channels ]] && chosen_channels=$(head -n1 <<<"$chans" || echo 1)

  echo "FORMAT=$chosen_format RATE=$chosen_rate CHANNELS=$chosen_channels"
}

start_recording() {
  mkdir -p "$(dirname "$FILE")"
  mkdir -p "$(dirname "$PID_FILE")"
  local dev params FORMAT RATE CHANNELS
  dev=$(detect_default_device)
  params=$(probe_params "$dev")
  eval "$params"   # sets FORMAT RATE CHANNELS
  echo "Recording from device '$dev' format=$FORMAT rate=$RATE channels=$CHANNELS"
  set -x
  nohup arecord -D "$dev" -f "$FORMAT" -r "$RATE" -c "$CHANNELS" "$FILE.wav" --duration="$MAX_DURATION" &>/dev/null &
  set +x
  echo $! >"$PID_FILE"
}

# Optional post-processing (call before transcription) to normalize for Whisper:
normalize_audio() {
  if command -v ffmpeg &>/dev/null; then
    ffmpeg -y -i "$FILE.wav" -ac 1 -ar 16000 -sample_fmt s16 "${FILE}-norm.wav" &>/dev/null && mv "${FILE}-norm.wav" "$FILE.wav"
  fi
}

#start_recording() {
#  mkdir -p "$(dirname "$FILE")"
#  mkdir -p "$(dirname "$PID_FILE")"
#  echo "Starting new recording..."
#  set -x
#  nohup arecord --device="$AUDIO_INPUT" --format cd "$FILE.wav" --duration="$MAX_DURATION" &>/dev/null &
#  set +x
#  echo $! >"$PID_FILE"
#}

stop_recording() {
  echo "Stopping recording..."
  if [ -s "$PID_FILE" ]; then
    local pid
    pid=$(<"$PID_FILE")
    rm -f "$PID_FILE"
    kill "$pid" && wait "$pid" 2>/dev/null || killall -w arecord
    return 0
  fi
  echo "No recording process found."

}

output_transcript() {
  perl -pi -e 'chomp if eof' "$FILE.txt"
  #xdotool type --clearmodifiers --file "$FILE.txt"
  xclip -selection clipboard < "$FILE.txt"
}

transcribe_with_openai() {
  if [[ ! -f "$FILE.wav" ]]; then
    echo "Audio file not found: $FILE.wav"
    exit 1
  fi
  curl --silent --fail --request POST \
    --url https://api.openai.com/v1/audio/transcriptions \
    --header "Authorization: Bearer $OPEN_AI_TOKEN" \
    --header 'Content-Type: multipart/form-data' \
    --form file="@$FILE.wav" \
    --form model=whisper-1 \
    --form response_format=text \
    -o "${FILE}.txt"
}

transcribe_with_deepgram() {
  curl --silent --fail --request POST \
    --url 'https://api.deepgram.com/v1/listen?smart_format=true' \
    --header "Authorization: Token $DEEPGRAM_TOKEN" \
    --header 'Content-Type: audio/wav' \
    --data-binary "@$FILE.wav" \
    -o "${FILE}.json"
  jq '.results.channels[0].alternatives[0].transcript' -r "${FILE}.json" >"${FILE}.txt"
}

transcript() {
  set +u
  if [[ -z "$DEEPGRAM_TOKEN" ]]; then
    transcribe_with_openai
  else
    transcribe_with_deepgram
  fi
  set -u
}

sanity_check() {
  for cmd in xdotool arecord killall jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
      echo >&2 "Error: command $cmd not found."
      exit 1
    fi
  done
  set +u
  if [[ -z "$DEEPGRAM_TOKEN" ]] && [[ -z "$OPEN_AI_TOKEN" ]]; then
    echo >&2 "You must set the DEEPGRAM_TOKEN or OPEN_AI_TOKEN environment variable."
    exit 1
  fi
  set -u
}

main() {
  sanity_check

  if [[ -f "$PID_FILE" ]]; then
    stop_recording
    transcript
    output_transcript
  else
    start_recording
  fi
}

main
