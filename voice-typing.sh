#!/usr/bin/env bash
# usage: exec ./voice-typing.sh twice to start and stop recording
# Dependencies: curl, jq, arecord, xdotool, killall

set -euo pipefail
IFS=$'\n\t'

# Configuration
# Session file holds variables across the two invocations (FILE path and recorder PID)
readonly SESSION_FILE="${HOME}/.local/state/voice-type/session.env"
readonly MAX_DURATION=3600
readonly AUDIO_INPUT='hw:2,0' # Use `arecord -l` to list available devices
source "$HOME/.config/linux-voice-type"      # Ensure this file has restrictive permissions

readonly PREFERRED_FORMATS=(S16_LE S24_LE S24_3LE S32_LE)
readonly PREFERRED_RATES=(48000 44100 16000 32000)
readonly PREFERRED_CHANNELS=(1 2)

# FILE and PID will be set dynamically; shellcheck disable=SC2034 for sourced vars
# (They are intentionally global for subsequent function calls.)
FILE=""
PID=""

# Ensure state directory exists
ensure_state_dirs() {
  mkdir -p "${HOME}/.local/state/voice-type" || true
  mkdir -p "${HOME}/.local/var/voice-type" || true
}

detect_default_device() {
  if command -v wpctl &>/dev/null; then
    echo "default"; return
  fi
  if command -v pactl &>/dev/null; then
    echo "default"; return
  fi
  local card dev
  if arecord -l 2>/dev/null | awk '/card [0-9]+:/ {print; exit}' | \
     sed -E 's/.*card ([0-9]+).*, device ([0-9]+).*/\1 \2/' >/dev/null; then
    read -r card dev < <(arecord -l | awk '/card [0-9]+:/ {print; exit}' | sed -E 's/.*card ([0-9]+).*, device ([0-9]+).*/\1 \2/')
    echo "plughw:${card},${dev}"; return
  fi
  echo "default"
}

sanity_check() {
  for cmd in xdotool arecord killall jq curl timeout; do
    if ! command -v "$cmd" &>/dev/null; then
      echo >&2 "Error: command $cmd not found."; exit 1
    fi
  done
  set +u
  if [[ -z "${DEEPGRAM_TOKEN:-}" && -z "${OPEN_AI_TOKEN:-}" ]]; then
    echo >&2 "You must set the DEEPGRAM_TOKEN or OPEN_AI_TOKEN environment variable."; exit 1
  fi
  set -u
}

probe_params() {
  local dev="$1"
  local dump
  dump="$(timeout 2 arecord -D "$dev" -d 1 --dump-hw-params /dev/null 2>&1 || true)"
  if [[ -z "$dump" ]]; then
    echo "FORMAT=S16_LE RATE=44100 CHANNELS=1"; return
  fi
  local formats chans_line chans_list rate_line rate_lo rate_hi chosen_format chosen_rate chosen_channels
  formats=$(awk '/^FORMAT:/ {for(i=2;i<=NF;i++) print $i}' <<<"$dump")
  chans_line=$(awk '/^CHANNELS:/ {print; exit}' <<<"$dump")
  if [[ $chans_line =~ \[([0-9]+)[[:space:]]+([0-9]+)\] ]]; then
    chans_list="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  else
    chans_list=$(awk '/^CHANNELS:/ {for(i=2;i<=NF;i++) print $i}' <<<"$dump")
  fi
  rate_line=$(awk '/^RATE:/ {print; exit}' <<<"$dump")
  if [[ $rate_line =~ \[([0-9]+)[[:space:]]+([0-9]+)\] ]]; then
    rate_lo="${BASH_REMATCH[1]}"; rate_hi="${BASH_REMATCH[2]}"
  fi
  chosen_format=""
  for f in "${PREFERRED_FORMATS[@]}"; do
    if grep -qw "$f" <<<"$formats"; then chosen_format="$f"; break; fi
  done
  [[ -z $chosen_format ]] && chosen_format=$(head -n1 <<<"$formats" || echo S16_LE)
  chosen_rate=""
  if [[ -n ${rate_lo:-} && -n ${rate_hi:-} ]]; then
    for r in "${PREFERRED_RATES[@]}"; do
      if (( r >= rate_lo && r <= rate_hi )); then chosen_rate="$r"; break; fi
    done
  fi
  [[ -z $chosen_rate ]] && chosen_rate=44100
  chosen_channels=""
  for c in "${PREFERRED_CHANNELS[@]}"; do
    if grep -qw "$c" <<<"$chans_list"; then chosen_channels="$c"; break; fi
  done
  [[ -z $chosen_channels ]] && chosen_channels=1
  echo "FORMAT=$chosen_format RATE=$chosen_rate CHANNELS=$chosen_channels"
}

start_recording() {
  ensure_state_dirs
  # Pick a new timestamped file only for a new session
  FILE="${HOME}/.local/var/voice-type/recording-$(date +%Y%m%d-%H%M%S)"
  local dev params FORMAT RATE CHANNELS
  dev=$(detect_default_device)
  params=$(probe_params "$dev")
  eval "$params"  # sets FORMAT RATE CHANNELS
  echo "Recording from device '$dev' format=$FORMAT rate=$RATE channels=$CHANNELS"
  set -x
  nohup arecord -D "$dev" -f "$FORMAT" -r "$RATE" -c "$CHANNELS" "$FILE.wav" --duration="$MAX_DURATION" &>>"$FILE.arecord.log" &
  PID=$!
  set +x
  # Initialize / append to session file
  : > "$SESSION_FILE"
  echo "FILE=$FILE" >> "$SESSION_FILE"
  echo "PID=$PID" >> "$SESSION_FILE"
  echo "Started session: FILE=$FILE PID=$PID"
}

normalize_audio() {
  if command -v ffmpeg &>/dev/null && [[ -f "$FILE.wav" ]]; then
    ffmpeg -y -i "$FILE.wav" -ac 1 -ar 16000 -sample_fmt s16 "${FILE}-norm.wav" &>>"$FILE.log" && mv "${FILE}-norm.wav" "$FILE.wav"
  fi
}

stop_recording() {
  echo "Stopping recording..."
  if [[ -z "${PID:-}" ]]; then
    echo "No PID in session; nothing to stop."; return 0
  fi
  # If process doesn't exist, treat as stale
  if [[ ! -d "/proc/$PID" ]]; then
    echo "Process $PID not running; stale session."; return 0
  fi
  if [[ -r "/proc/$PID/cmdline" ]]; then
    local cmdline
    cmdline=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)
    if [[ -n "$cmdline" && ! "$cmdline" =~ arecord ]]; then
      echo "Note: PID $PID cmdline does not look like arecord: $cmdline"
    fi
  fi
  kill "$PID" 2>/dev/null || true
  local waited=0 max_wait=50
  while kill -0 "$PID" 2>/dev/null; do
    if (( waited >= max_wait )); then
      echo "PID $PID did not exit after SIGTERM; sending SIGKILL..."
      kill -9 "$PID" 2>/dev/null || true
      break
    fi
    sleep 0.1; ((waited++))
  done
  if kill -0 "$PID" 2>/dev/null; then
    echo "Attempting killall arecord as fallback..."
    killall -q arecord || true
    sleep 0.2
  fi
  if kill -0 "$PID" 2>/dev/null; then
    echo "Warning: Failed to stop process $PID (stale)."
  else
    echo "Stopped recording (pid $PID)."
  fi
}

output_transcript() {
  if [[ -f "$FILE.txt" ]]; then
    perl -pi -e 'chomp if eof' "$FILE.txt"
    xclip -selection clipboard < "$FILE.txt" &>>"$FILE.log" || true
  else
    echo "Transcript file missing: $FILE.txt" >&2
  fi
}

transcribe_with_openai() {
  if [[ ! -f "$FILE.wav" ]]; then
    echo "Audio file not found: $FILE.wav"; return 1
  fi
  curl --fail --request POST \
    --url https://api.openai.com/v1/audio/transcriptions \
    --header "Authorization: Bearer $OPEN_AI_TOKEN" \
    --header 'Content-Type: multipart/form-data' \
    --form file="@$FILE.wav" \
    --form model=whisper-1 \
    --form response_format=text \
    -o "${FILE}.txt" &>>"$FILE.log"
}

transcribe_with_deepgram() {
  if [[ ! -f "$FILE.wav" ]]; then
    echo "Audio file not found: $FILE.wav"; return 1
  fi
  DPARAMS="model=nova-3-general&smart_format=true&detect_language=true"
  curl --fail --request POST \
    --url "https://api.deepgram.com/v1/listen?${DPARAMS}" \
    --header "Authorization: Token $DEEPGRAM_TOKEN" \
    --header 'Content-Type: audio/wav' \
    --data-binary "@$FILE.wav" \
    -o "${FILE}.json" &>>"$FILE.log"
  if [[ -f "$FILE.json" ]]; then
    jq '.results.channels[0].alternatives[0].transcript' -r "${FILE}.json" >"${FILE}.txt" || true
  fi
}

transcript() {
  set +u
  if [[ -z "${DEEPGRAM_TOKEN:-}" ]]; then
    transcribe_with_openai || true
  else
    transcribe_with_deepgram || true
  fi
  set -u
}

cleanup_session() {
  rm -f "$SESSION_FILE" || true
}

main() {
  ensure_state_dirs
  sanity_check
  if [[ -f "$SESSION_FILE" ]]; then
    # Second invocation: load session, stop and transcribe
    # shellcheck disable=SC1090
    source "$SESSION_FILE" || true
    if [[ -z "${FILE:-}" ]]; then
      echo "Session file missing FILE variable; aborting." >&2
      cleanup_session
      exit 1
    fi
    stop_recording || true
    normalize_audio || true
    transcript || true
    output_transcript || true
    cleanup_session
  else
    # First invocation: start new recording
    start_recording
  fi
}

main
