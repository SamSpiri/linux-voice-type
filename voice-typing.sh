#!/usr/bin/env bash
# usage: exec ./voice-typing.sh twice to start and stop recording
# Dependencies: curl, jq, arecord, xdotool, killall
# Added: flock for locking concurrent invocations

set -euo pipefail
IFS=$'\n\t'

# Configuration
# Session file holds variables across the two invocations (FILE path and recorder PID)
readonly SESSION_FILE="${HOME}/.local/state/voice-type/session.env"
readonly LOCK_FILE="${HOME}/.local/state/voice-type/lock"  # lock to serialize start/stop sequences
readonly MAX_DURATION=3600
readonly AUDIO_INPUT='hw:2,0' # Use `arecord -l` to list available devices
source "$HOME/.config/linux-voice-type"      # Ensure this file has restrictive permissions

# Prefer higher bit-depth first: 24-bit (packed & 3-byte), then 32-bit, then 16-bit.
readonly PREFERRED_FORMATS=(S24_LE S24_3LE S32_LE S16_LE)
# New preference arrays for decision logic
readonly RECORD_FORMAT_PREF=(S32_LE S24_LE S24_3LE S24_32LE S16_LE)
readonly API_FORMAT_PREF=(S24_LE S32_LE S16_LE)

# FILE and PID will be set dynamically; shellcheck disable=SC2034 for sourced vars
# (They are intentionally global for subsequent function calls.)
FILE=""
PID=""

# default logfile before FILE is known; will be switched to $FILE.log after start_recording
readonly DEFAULT_LOGFILE="${HOME}/.local/var/voice-type/voice-type.log"
LOGFILE="$DEFAULT_LOGFILE"

# Lock file FD (chosen high to avoid clashes); will be assigned in acquire_lock
LOCK_FD=0

# Send desktop notification if possible
notify() {
  # Allow disabling via VOICE_TYPE_NO_NOTIFY=1
  if [[ "${VOICE_TYPE_NO_NOTIFY:-0}" == "1" ]]; then return 0; fi
  if command -v notify-send &>/dev/null; then
    local title="$1" body="${2:-}"
    # shellcheck disable=SC2016
    notify-send --app-name="VoiceType" --icon=audio-input-microphone "$title" "$body"
    echo "notify: $title ${body}" &>>"$LOGFILE"
  fi
}

# Ensure state directory exists
ensure_state_dirs() {
  mkdir -p "${HOME}/.local/state/voice-type" || true
  mkdir -p "${HOME}/.local/var/voice-type" || true
}

# Acquire a non-blocking lock; fail with notification if already locked
acquire_lock() {
  ensure_state_dirs
  # shellcheck disable=SC3045 # using exec with FD assignment is intentional
  exec {LOCK_FD}>"$LOCK_FILE" || {
    echo "Failed to open lock file $LOCK_FILE" &>>"$LOGFILE"; return 1;
  }
  if ! flock -n "$LOCK_FD"; then
    echo "Lock busy: another voice-typing operation in progress." &>>"$LOGFILE"
    notify "Voice typing busy" "Another operation is in progress"
    return 1
  fi
  # Record metadata in lock file (best-effort; not required for locking itself)
  {
    echo "PID=$$"; echo "TIME=$(date -Is)"; echo "ACTION_PENDING=$( [[ -f $SESSION_FILE ]] && echo stop || echo start )";
  } >"$LOCK_FILE" 2>/dev/null || true
  echo "acquire_lock: obtained lock (fd=$LOCK_FD action=$( [[ -f $SESSION_FILE ]] && echo stop || echo start ))" &>>"$LOGFILE"
}

release_lock() {
  if (( LOCK_FD > 0 )); then
    flock -u "$LOCK_FD" 2>/dev/null || true
    # shellcheck disable=SC3045
    exec {LOCK_FD}>&- 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
    echo "release_lock: released lock" &>>"$LOGFILE"
  fi
}

# Detect default device (PipeWire/Pulse or first ALSA card)
detect_default_device() {
  if command -v wpctl &>/dev/null; then
    echo "default"
    echo "default" &>>"$LOGFILE"
    return
  fi
  if command -v pactl &>/dev/null; then
    echo "default"
    echo "default" &>>"$LOGFILE"
    return
  fi
  local card dev
  if arecord -l 2>/dev/null | awk '/card [0-9]+:/ {print; exit}' | \
     sed -E 's/.*card ([0-9]+).*, device ([0-9]+).*/\1 \2/' >/dev/null; then
    read -r card dev < <(arecord -l | awk '/card [0-9]+:/ {print; exit}' | sed -E 's/.*card ([0-9]+).*, device ([0-9]+).*/\1 \2/')
    echo "plughw:${card},${dev}"
    echo "plughw:${card},${dev}" &>>"$LOGFILE"
    return
  fi
  echo "default"
  echo "default" &>>"$LOGFILE"
}

sanity_check() {
  for cmd in xdotool arecord killall jq curl timeout flock; do
    if ! command -v "$cmd" &>/dev/null; then
      echo >&2 "Error: command $cmd not found."
      echo "Error: command $cmd not found." &>>"$LOGFILE"
      notify "Missing dependency" "$cmd not found"
      exit 1
    fi
  done
  set +u
  if [[ -z "${DEEPGRAM_TOKEN:-}" && -z "${OPEN_AI_TOKEN:-}" ]]; then
    echo >&2 "You must set the DEEPGRAM_TOKEN or OPEN_AI_TOKEN environment variable."
    echo "You must set the DEEPGRAM_TOKEN or OPEN_AI_TOKEN environment variable." &>>"$LOGFILE"
    notify "Voice typing error" "Missing API token"
    exit 1
  fi
  set -u
}

probe_params() {
  local dev="$1"
  local dump
  dump="$(timeout 0.1 arecord -D "$dev" -d 1 --dump-hw-params /dev/null 2>&1 || true)"
  if [[ -z "$dump" ]]; then
    echo "FORMAT=S24_LE RATE=22000 CHANNELS=1 RAW_FORMATS='S24_LE S16_LE'"
    echo "FORMAT=S24_LE RATE=22000 CHANNELS=1 RAW_FORMATS='S24_LE S16_LE'" &>>"$LOGFILE"
    return
  fi
  local formats chans_line chans_list rate_line rate_lo rate_hi chosen_format chosen_rate chosen_channels
  formats=$(awk '/^FORMAT:/ {for(i=2;i<=NF;i++) print $i}' <<<"$dump" | tr '\n' ' ')
  # capture packed/container variants that may appear (S24_3LE, S24_32LE)
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
  [[ -z $chosen_format ]] && chosen_format=$(awk '{print $1; exit}' <<<"$formats" || echo S16_LE)
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
  echo "FORMAT=$chosen_format RATE=$chosen_rate CHANNELS=$chosen_channels RAW_FORMATS='$formats'"
  echo "FORMAT=$chosen_format RATE=$chosen_rate CHANNELS=$chosen_channels RAW_FORMATS='$formats'" &>>"$LOGFILE"
}

choose_formats() {
  # Inputs: RAW_FORMATS space separated list; optional env overrides.
  local available="$RAW_FORMATS" f record api
  # Apply override if valid
  if [[ -n "${VOICE_TYPE_FORCE_RECORD_FORMAT:-}" && $available =~ (^|[[:space:]])${VOICE_TYPE_FORCE_RECORD_FORMAT}( |$) ]]; then
    record="$VOICE_TYPE_FORCE_RECORD_FORMAT"
  else
    for f in "${RECORD_FORMAT_PREF[@]}"; do
      if grep -qw "$f" <<<"$available"; then record="$f"; break; fi
    done
  fi
  [[ -z $record ]] && record="S16_LE" # conservative fallback
  if [[ -n "${VOICE_TYPE_FORCE_API_FORMAT:-}" ]]; then
    api="$VOICE_TYPE_FORCE_API_FORMAT"
  else
    # Derive API format from record if acceptable
    case "$record" in
      S24_LE|S24_3LE|S24_32LE) api="S24_LE" ;;
      S32_LE) api="S32_LE" ;;
      S16_LE) api="S16_LE" ;;
      *) api="S16_LE" ;;
    esac
    # If api not in acceptable list, iterate preferences
    if ! [[ " ${API_FORMAT_PREF[*]} " =~ " $api " ]]; then
      for f in "${API_FORMAT_PREF[@]}"; do
        if grep -qw "$f" <<<"$available"; then api="$f"; break; fi
      done
    fi
  fi
  # Final fallback
  [[ -z $api ]] && api="S16_LE"
  RECORD_FORMAT="$record"
  API_FORMAT="$api"
  FORMAT="$RECORD_FORMAT" # backward compatibility alias
  if [[ "${VOICE_TYPE_LOG_VERBOSE:-0}" == "1" ]]; then
    echo "choose_formats: available=[$available] record=$RECORD_FORMAT api=$API_FORMAT overrides(rec=${VOICE_TYPE_FORCE_RECORD_FORMAT:-none},api=${VOICE_TYPE_FORCE_API_FORMAT:-none})" &>>"$LOGFILE"
  fi
}

start_recording() {
  ensure_state_dirs
  FILE="${HOME}/.local/var/voice-type/recording-$(date +%Y%m%d-%H%M%S)"
  LOGFILE="${FILE}.log"
  local dev params FORMAT RATE CHANNELS RAW_FORMATS
  dev=$(detect_default_device)
  params=$(probe_params "$dev")
  eval "$params"  # sets FORMAT RATE CHANNELS RAW_FORMATS
  choose_formats
  echo "Recording from device '$dev' record_format=$RECORD_FORMAT api_format=$API_FORMAT rate=$RATE channels=$CHANNELS" &>>"$LOGFILE"
  set -x
  nohup arecord -D "$dev" -f "$RECORD_FORMAT" -r "$RATE" -c "$CHANNELS" "$FILE.wav" --duration="$MAX_DURATION" &>>"$FILE.arecord.log" &
  PID=$!
  set +x
  # Initialize / append to session file
  : > "$SESSION_FILE"
  echo "FILE=$FILE" >> "$SESSION_FILE"
  echo "PID=$PID" >> "$SESSION_FILE"
  echo "RECORD_FORMAT=$RECORD_FORMAT" >> "$SESSION_FILE"
  echo "API_FORMAT=$API_FORMAT" >> "$SESSION_FILE"
  echo "RATE=$RATE" >> "$SESSION_FILE"
  echo "CHANNELS=$CHANNELS" >> "$SESSION_FILE"
  echo "RAW_FORMATS='$RAW_FORMATS'" >> "$SESSION_FILE"
  echo "Started session: FILE=$FILE PID=$PID RECORD_FORMAT=$RECORD_FORMAT API_FORMAT=$API_FORMAT RATE=$RATE CHANNELS=$CHANNELS" &>>"$LOGFILE"
}

prepare_api_audio() {
  # Create or refresh API copy (FILE.api.wav) preserving API_FORMAT and applying loudnorm.
  if ! command -v ffmpeg &>/dev/null; then
    echo "prepare_api_audio: ffmpeg not installed; using original recording" &>>"$LOGFILE"
    return 0
  fi
  if [[ ! -f "$FILE.wav" ]]; then
    echo "prepare_api_audio: source file missing ($FILE.wav)" &>>"$LOGFILE"
    return 1
  fi
  local TARGET_FORMAT TARGET_SAMPLE_FMT TARGET_RATE TARGET_CHANNELS api_out
  TARGET_FORMAT="${API_FORMAT:-${RECORD_FORMAT:-S16_LE}}"
  TARGET_RATE="${RATE:-44100}"
  TARGET_CHANNELS="${CHANNELS:-1}"
  api_out="${FILE}.api.wav"
  case "$TARGET_FORMAT" in
    S16_LE) TARGET_SAMPLE_FMT="s16" ;;
    S24_LE|S24_3LE|S24_32LE) TARGET_SAMPLE_FMT="s24" ;;
    S32_LE) TARGET_SAMPLE_FMT="s32" ;;
    *) TARGET_SAMPLE_FMT="s16" ;;
  esac
  echo "prepare_api_audio: building API copy target_fmt=$TARGET_FORMAT ffmpeg_sample_fmt=$TARGET_SAMPLE_FMT rate=$TARGET_RATE ch=$TARGET_CHANNELS" &>>"$LOGFILE"
  local pass1_output pass1_json measured_I measured_LRA measured_TP measured_thresh offset
  pass1_output=$(ffmpeg -hide_banner -nostats -y -i "$FILE.wav" -af loudnorm=I=-23:LRA=7:TP=-2:print_format=json -f null - 2>&1 || true)
  pass1_json=$(awk 'BEGIN{capture=0} /^\{/ {capture=1} capture {print} /^\}/ {if(capture){capture=0}}' <<<"$pass1_output")
  if [[ -n "$pass1_json" ]]; then
    measured_I=$(jq -r '.input_i' <<<"$pass1_json" 2>/dev/null || true)
    measured_LRA=$(jq -r '.input_lra' <<<"$pass1_json" 2>/dev/null || true)
    measured_TP=$(jq -r '.input_tp' <<<"$pass1_json" 2>/dev/null || true)
    measured_thresh=$(jq -r '.input_thresh' <<<"$pass1_json" 2>/dev/null || true)
    offset=$(jq -r '.target_offset' <<<"$pass1_json" 2>/dev/null || true)
    if [[ -n "$measured_I" && "$measured_I" != "null" ]]; then
      if ffmpeg -hide_banner -nostats -y -i "$FILE.wav" -af "loudnorm=I=-23:LRA=7:TP=-2:measured_I=$measured_I:measured_LRA=$measured_LRA:measured_TP=$measured_TP:measured_thresh=$measured_thresh:offset=$offset:linear=true:print_format=summary" -ac "$TARGET_CHANNELS" -ar "$TARGET_RATE" -sample_fmt "$TARGET_SAMPLE_FMT" "$api_out" &>>"$LOGFILE" 2>&1; then
        echo "prepare_api_audio: two-pass loudnorm complete -> $api_out" &>>"$LOGFILE"
      else
        echo "prepare_api_audio: loudnorm second pass failed; fallback conversion" &>>"$LOGFILE"
      fi
    fi
  fi
  if [[ ! -f "$api_out" ]]; then
    if ffmpeg -y -i "$FILE.wav" -ac "$TARGET_CHANNELS" -ar "$TARGET_RATE" -sample_fmt "$TARGET_SAMPLE_FMT" "$api_out" &>>"$LOGFILE" 2>&1; then
      echo "prepare_api_audio: fallback conversion done -> $api_out" &>>"$LOGFILE"
    else
      echo "prepare_api_audio: conversion failed; using original" &>>"$LOGFILE"
      return 1
    fi
  fi
  if [[ "${VOICE_TYPE_KEEP_ORIGINAL:-1}" == "0" ]]; then
    mv "$api_out" "$FILE.wav" && echo "prepare_api_audio: replaced original with API copy (KEEP_ORIGINAL=0)" &>>"$LOGFILE"
  fi
}

# Backward compatibility wrapper (old name used in main)
normalize_audio() { prepare_api_audio; }

transcribe_with_openai() {
  local src
  src="${FILE}.api.wav"
  [[ -f "$src" ]] || src="${FILE}.wav"
  if [[ ! -f "$src" ]]; then
    echo "Audio file not found: $src" &>>"$LOGFILE"
    return 1
  fi
  curl --fail --request POST \
    --url https://api.openai.com/v1/audio/transcriptions \
    --header "Authorization: Bearer $OPEN_AI_TOKEN" \
    --header 'Content-Type: multipart/form-data' \
    --form file="@$src" \
    --form model=whisper-1 \
    --form response_format=text \
    -o "${FILE}.txt" &>>"$LOGFILE"
  echo "transcribe_with_openai: request finished (input $(basename "$src") output ${FILE}.txt)" &>>"$LOGFILE"
}

transcribe_with_deepgram() {
  local src
  src="${FILE}.api.wav"
  [[ -f "$src" ]] || src="${FILE}.wav"
  if [[ ! -f "$src" ]]; then
    echo "Audio file not found: $src" &>>"$LOGFILE"
    return 1
  fi
  DPARAMS="model=nova-3-general&smart_format=true&detect_language=true"
  curl --fail --request POST \
    --url "https://api.deepgram.com/v1/listen?${DPARAMS}" \
    --header "Authorization: Token $DEEPGRAM_TOKEN" \
    --header 'Content-Type: audio/wav' \
    --data-binary "@$src" \
    -o "${FILE}.json" &>>"$LOGFILE"
  echo "transcribe_with_deepgram: request finished (input $(basename "$src") output ${FILE}.json)" &>>"$LOGFILE"
  if [[ -f "$FILE.json" ]]; then
    jq '.results.channels[0].alternatives[0].transcript' -r "${FILE}.json" >"${FILE}.txt" || true
    echo "transcribe_with_deepgram: wrote ${FILE}.txt" &>>"$LOGFILE"
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
  echo "cleanup_session: removed $SESSION_FILE" &>>"$LOGFILE"
}

main() {
  ensure_state_dirs
  sanity_check
  if ! acquire_lock; then
    exit 1
  fi
  trap release_lock EXIT
  if [[ -f "$SESSION_FILE" ]]; then
    # Stop phase
    source "$SESSION_FILE" || true
    if [[ -z "${FILE:-}" ]]; then
      echo "Session file missing FILE variable; aborting." &>>"$LOGFILE"
      cleanup_session
      notify "Voice typing error" "Session corrupt"
      exit 1
    fi
    LOGFILE="${FILE}.log"
    if ! kill -0 "${PID:-0}" 2>/dev/null && [[ ! -f "${FILE}.wav" ]]; then
      echo "Fallback: no arecord process and no audio file; starting new recording instead." &>>"$LOGFILE"
      cleanup_session
      start_recording
      notify "Recording started" "Tigger again to stop"
      return
    fi
    stop_recording || true
    prepare_api_audio || true
    transcript || true
    output_transcript || true
    cleanup_session
  else
    start_recording
    notify "Recording started" "Trigger again to stop"
  fi
}

main
