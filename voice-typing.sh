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

# Add timeout to sanity_check list
sanity_check() {
  for cmd in xdotool arecord killall jq curl timeout; do
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

# Replace probe_params with non-hanging version
probe_params() {
  local dev="$1"
  # Use timeout + a 1s duration so arecord exits; ignore non-zero exit
  local dump
  dump="$(timeout 2 arecord -D "$dev" -d 1 --dump-hw-params /dev/null 2>&1 || true)"
  if [[ -z "$dump" ]]; then
    echo "FORMAT=S16_LE RATE=44100 CHANNELS=1"
    return
  fi

  # Extract FORMAT tokens
  local formats
  formats=$(awk '/^FORMAT:/ {for(i=2;i<=NF;i++) print $i}' <<<"$dump")

  # Extract CHANNELS range or list
  local chans_line
  chans_line=$(awk '/^CHANNELS:/ {print; exit}' <<<"$dump")
  local chans_list
  if [[ $chans_line =~ \[([0-9]+)[[:space:]]+([0-9]+)\] ]]; then
    # Range: build a minimal list (1..2..N) for preference matching
    chans_list="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  else
    chans_list=$(awk '/^CHANNELS:/ {for(i=2;i<=NF;i++) print $i}' <<<"$dump")
  fi

  # Extract RATE range
  local rate_line
  rate_line=$(awk '/^RATE:/ {print; exit}' <<<"$dump")
  local rate_lo rate_hi
  if [[ $rate_line =~ \[([0-9]+)[[:space:]]+([0-9]+)\] ]]; then
    rate_lo="${BASH_REMATCH[1]}"
    rate_hi="${BASH_REMATCH[2]}"
  fi

  # Choose format
  local chosen_format=""
  for f in "${PREFERRED_FORMATS[@]}"; do
    if grep -qw "$f" <<<"$formats"; then chosen_format="$f"; break; fi
  done
  [[ -z $chosen_format ]] && chosen_format=$(head -n1 <<<"$formats" || echo S16_LE)

  # Choose rate
  local chosen_rate=""
  if [[ -n $rate_lo && -n $rate_hi ]]; then
    for r in "${PREFERRED_RATES[@]}"; do
      if (( r >= rate_lo && r <= rate_hi )); then chosen_rate="$r"; break; fi
    done
  fi
  [[ -z $chosen_rate ]] && chosen_rate=44100

  # Choose channels
  local chosen_channels=""
  for c in "${PREFERRED_CHANNELS[@]}"; do
    if grep -qw "$c" <<<"$chans_list"; then chosen_channels="$c"; break; fi
  done
  [[ -z $chosen_channels ]] && chosen_channels=1

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
  nohup arecord -D "$dev" -f "$FORMAT" -r "$RATE" -c "$CHANNELS" "$FILE.wav" --duration="$MAX_DURATION" &>>$FILE.arecord.log &
  echo $! >"$PID_FILE"
  set +x
}

# Optional post-processing (call before transcription) to normalize for Whisper:
normalize_audio() {
  if command -v ffmpeg &>/dev/null; then
    ffmpeg -y -i "$FILE.wav" -ac 1 -ar 16000 -sample_fmt s16 "${FILE}-norm.wav" &>>$FILE.log && mv "${FILE}-norm.wav" "$FILE.wav"
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

    # If process doesn't exist, remove stale pidfile and return
    if [ ! -d "/proc/$pid" ]; then
      echo "Process $pid not running (no /proc/$pid). Removing stale pidfile."
      rm -f "$PID_FILE" || true
      return 0
    fi

    # Try to verify it's the expected recorder (best-effort). If not, warn but continue.
    if [ -r "/proc/$pid/cmdline" ]; then
      local cmdline
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
      if [[ -n "$cmdline" && ! "$cmdline" =~ arecord ]]; then
        echo "Note: PID $pid cmdline does not look like arecord: $cmdline"
      fi
    fi

    # Send polite SIGTERM first
    kill "$pid" 2>/dev/null || true

    # Wait up to ~5s for process to exit
    local waited=0
    local max_wait=50 # 50 * 0.1s = 5s
    while kill -0 "$pid" 2>/dev/null; do
      if (( waited >= max_wait )); then
        echo "Process $pid did not exit after SIGTERM; sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
        break
      fi
      sleep 0.1
      ((waited++))
    done

    # If it still exists, attempt to stop by process name as a last resort
    if kill -0 "$pid" 2>/dev/null; then
      echo "Attempting killall arecord as a fallback..."
      killall -q arecord || true
      sleep 0.2
    fi

    # Final check - don't return non-zero to avoid aborting under set -e; just warn.
    if kill -0 "$pid" 2>/dev/null; then
      echo "Warning: Failed to stop process $pid; will remove stale pidfile and continue."
      rm -f "$PID_FILE" || true
    else
      echo "Stopped recording (pid $pid). Removing pidfile."
      rm -f "$PID_FILE" || true
    fi

    return 0
  fi
  echo "No recording process found."

}

output_transcript() {
  perl -pi -e 'chomp if eof' "$FILE.txt"
  #xdotool type --clearmodifiers --file "$FILE.txt"
  xclip -selection clipboard < "$FILE.txt" &>>$FILE.log
}

transcribe_with_openai() {
  if [[ ! -f "$FILE.wav" ]]; then
    echo "Audio file not found: $FILE.wav"
    exit 1
  fi
  curl --fail --request POST \
    --url https://api.openai.com/v1/audio/transcriptions \
    --header "Authorization: Bearer $OPEN_AI_TOKEN" \
    --header 'Content-Type: multipart/form-data' \
    --form file="@$FILE.wav" \
    --form model=whisper-1 \
    --form response_format=text \
    -o "${FILE}.txt" &>>$FILE.log
}

transcribe_with_deepgram() {
  curl --fail --request POST \
    --url 'https://api.deepgram.com/v1/listen?smart_format=true' \
    --header "Authorization: Token $DEEPGRAM_TOKEN" \
    --header 'Content-Type: audio/wav' \
    --data-binary "@$FILE.wav" \
    -o "${FILE}.json" &>>$FILE.log
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

main() {
  sanity_check

  if [[ -f "$PID_FILE" ]]; then
    stop_recording || true
    transcript
    output_transcript
  else
    start_recording
  fi
}

main
