#!/usr/bin/env bash
# usage: exec ./voice-typing.sh twice to start and stop recording
# Dependencies: curl, jq, arecord, xdotool, killall, flock, xclip, perl

set -euo pipefail
IFS=$'\n\t'

# Configuration
# Session file holds variables across the two invocations (FILE path and recorder PID)
readonly SESSION_FILE="${HOME}/.local/state/voice-type/session.env"
readonly LOCK_FILE="${HOME}/.local/state/voice-type/lock"  # lock to serialize start/stop sequences
readonly MAX_DURATION=3600
readonly AUDIO_INPUT='hw:2,0' # Use `arecord -l` to list available devices
source "$HOME/.config/linux-voice-type"      # Ensure this file has restrictive permissions

# Preference arrays for decision logic (recording and API conversion)
# Order defines desirability; first match wins.
readonly RECORD_FORMAT_PREF=(S16_LE S32_LE S24_LE S24_3LE S24_32LE)
readonly API_FORMAT_PREF=(S16_LE S24_LE S32_LE)
readonly VOICE_TYPE_RECORD_RATE=22000
readonly VOICE_TYPE_TARGET_RATE=22000

# Silence compression configuration (optional)
# VOICE_TYPE_SILENCE_ENABLE=1 to activate (default 1)
# VOICE_TYPE_SILENCE_MAX=1.0 maximum length of any silence segment retained (seconds)
# VOICE_TYPE_SILENCE_THRESHOLD=-50dB loudness threshold defining silence
# VOICE_TYPE_SILENCE_MIN=0.3 minimum continuous silence duration before compression applies
# If ffmpeg is missing or filter fails, original audio is kept.

# FILE and PID will be set dynamically; shellcheck disable=SC2034 for sourced vars
FILE=""
PID=""

readonly DEFAULT_LOGFILE="${HOME}/.local/var/voice-type/voice-type.log"
LOGFILE="$DEFAULT_LOGFILE"
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
  for cmd in xdotool arecord killall jq curl timeout flock xclip perl; do
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

# Probe hardware params; choose preferred format and simple rate/channels.
probe_params() {
  local dev="$1" dump
  dump="$(timeout 0.1 arecord -D "$dev" -d 1 --dump-hw-params /dev/null 2>&1 || true)"
  if [[ -z "$dump" ]]; then
    echo "FORMAT=S16_LE RATE=44100 CHANNELS=1 RAW_FORMATS='S16_LE'"
    echo "probe_params: fallback (no dump) FORMAT=S16_LE RATE=44100 CHANNELS=1 RAW_FORMATS='S16_LE'" &>>"$LOGFILE"
    return
  fi
  local formats rate_line rate_lo rate_hi chans_line chans_list chosen_format chosen_rate chosen_channels
  formats=$(awk '/^FORMAT:/ {for(i=2;i<=NF;i++) print $i}' <<<"$dump" | tr '\n' ' ')
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
  # Choose format
  chosen_format=""
  for f in "${RECORD_FORMAT_PREF[@]}"; do
    if grep -qw "$f" <<<"$formats"; then chosen_format="$f"; break; fi
  done
  [[ -z $chosen_format ]] && chosen_format=$(awk '{print $1; exit}' <<<"$formats" || echo S16_LE)
  if [[ -n ${rate_lo:-} && -n ${rate_hi:-} ]]; then
    if (( rate_hi >= $VOICE_TYPE_RECORD_RATE )) && (( rate_lo <= $VOICE_TYPE_RECORD_RATE )); then
      chosen_rate=$VOICE_TYPE_RECORD_RATE
    elif (( rate_lo > $VOICE_TYPE_RECORD_RATE )); then
      chosen_rate=$rate_lo
    else
      chosen_rate=$rate_hi
    fi
  else
    chosen_rate=$VOICE_TYPE_RECORD_RATE
  fi
  # Channels: prefer mono (1) else first listed
  if grep -qw 1 <<<"$chans_list"; then chosen_channels=1; else chosen_channels=$(awk '{print $1; exit}' <<<"$chans_list" || echo 1); fi
  echo "FORMAT=$chosen_format RATE=$chosen_rate CHANNELS=$chosen_channels RAW_FORMATS='$formats'"
  echo "probe_params: FORMAT=$chosen_format RATE=$chosen_rate CHANNELS=$chosen_channels RAW_FORMATS='$formats'" &>>"$LOGFILE"
}

choose_formats() {
  local available="$RAW_FORMATS" f record api
  if [[ -n "${VOICE_TYPE_FORCE_RECORD_FORMAT:-}" && $available =~ (^|[[:space:]])${VOICE_TYPE_FORCE_RECORD_FORMAT}( |$) ]]; then
    record="$VOICE_TYPE_FORCE_RECORD_FORMAT"
  else
    for f in "${RECORD_FORMAT_PREF[@]}"; do
      if grep -qw "$f" <<<"$available"; then record="$f"; break; fi
    done
  fi
  [[ -z $record ]] && record="S16_LE"
  if [[ -n "${VOICE_TYPE_FORCE_API_FORMAT:-}" ]]; then
    api="$VOICE_TYPE_FORCE_API_FORMAT"
  else
    case "$record" in
      S24_LE|S24_3LE|S24_32LE) api="S24_LE" ;;
      S32_LE) api="S32_LE" ;;
      S16_LE) api="S16_LE" ;;
      *) api="S16_LE" ;;
    esac
    if ! [[ " ${API_FORMAT_PREF[*]} " =~ " $api " ]]; then
      for f in "${API_FORMAT_PREF[@]}"; do
        if grep -qw "$f" <<<"$available"; then api="$f"; break; fi
      done
    fi
  fi
  [[ -z $api ]] && api="S16_LE"
  RECORD_FORMAT="$record"
  API_FORMAT="$api"
  FORMAT="$RECORD_FORMAT"
  if [[ "${VOICE_TYPE_LOG_VERBOSE:-0}" == "1" ]]; then
    echo "choose_formats: available=[$available] record=$RECORD_FORMAT api=$API_FORMAT overrides(rec=${VOICE_TYPE_FORCE_RECORD_FORMAT:-none},api=${VOICE_TYPE_FORCE_API_FORMAT:-none})" &>>"$LOGFILE"
  fi
}

# Map ALSA/arecord format tokens to ffmpeg audio codec names
codec_for_format() {
  case "$1" in
    S16_LE) echo "pcm_s16le" ;;
    S24_LE|S24_3LE|S24_32LE) echo "pcm_s24le" ;;
    S32_LE) echo "pcm_s32le" ;;
    *) echo "pcm_s16le" ;;
  esac
}

# Compress long silence segments
# Uses ffmpeg silenceremove filter leaving up to leave_silence seconds.
compress_silence() {
  local infile="$1" outfile="$2" max silent_thresh min apply
  apply="${VOICE_TYPE_SILENCE_ENABLE:-1}"
  [[ "$apply" == "1" ]] || { echo "compress_silence: disabled" &>>"$LOGFILE"; return 0; }
  [[ -f "$infile" ]] || { echo "compress_silence: infile missing ($infile)" &>>"$LOGFILE"; return 1; }
  max="${VOICE_TYPE_SILENCE_MID:-1.0}"          # seconds of silence to retain
  silent_thresh="${VOICE_TYPE_SILENCE_THRESHOLD:--60dB}" # threshold defining silence
  min="${VOICE_TYPE_SILENCE_EDGE:-0.3}"          # minimum continuous silence duration to trigger compression

  local filter_spec
  filter_spec="silenceremove=start_periods=1:start_silence=${min}:start_threshold=${silent_thresh}:stop_periods=-1:stop_silence=${min}:stop_threshold=${silent_thresh}"

  # Try with -af first, capture stderr to inspect failures.
  local attempt_log success=0
  attempt_log="$(ffmpeg -hide_banner -nostats -y -i "$infile" -af "$filter_spec" "$outfile" 2>&1)" || true
  if [[ -f "$outfile" ]]; then
    success=1
  else
    if (( success == 0 )); then
      echo "compress_silence: filter application failed; keeping original (${attempt_log%%$'\n'*})" &>>"$LOGFILE"
      return 1
    fi
  fi
  return 0
}

start_recording() {
  ensure_state_dirs
  FILE="${HOME}/.local/var/voice-type/recording-$(date +%Y%m%d-%H%M%S)"
  LOGFILE="${FILE}.log"
  local dev params FORMAT RATE CHANNELS RAW_FORMATS
  dev=$(detect_default_device)
  params=$(probe_params "$dev")
  eval "$params"
  choose_formats
  echo "Recording from device '$dev' record_format=$RECORD_FORMAT api_format=$API_FORMAT rate=$RATE channels=$CHANNELS" &>>"$LOGFILE"
  set -x
  nohup arecord -D "$dev" -f "$RECORD_FORMAT" -r "$RATE" -c "$CHANNELS" "$FILE.wav" --duration="$MAX_DURATION" &>>"$FILE.arecord.log" &
  PID=$!
  set +x
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
  if ! command -v ffmpeg &>/dev/null; then echo "prepare_api_audio: ffmpeg not installed; using original recording" &>>"$LOGFILE"; return 0; fi
  if [[ ! -f "$FILE.wav" ]]; then echo "prepare_api_audio: source file missing ($FILE.wav)" &>>"$LOGFILE"; return 1; fi
  compress_silence "$FILE.wav" "${FILE}.nosilence.wav" && mv "${FILE}.wav" "${FILE}.orig.wav" && mv "${FILE}.nosilence.wav" "$FILE.wav" 2>/dev/null || true
  local TARGET_FORMAT TARGET_RATE TARGET_CHANNELS api_out TARGET_CODEC loudnorm_pass1 loudnorm_json measured_I measured_LRA measured_TP measured_thresh offset use_loudnorm
  TARGET_FORMAT="${API_FORMAT:-${RECORD_FORMAT:-S16_LE}}"
  TARGET_RATE="${VOICE_TYPE_TARGET_RATE:-${RATE:-44100}}"
  # Clamp overly high target rate unless explicitly forced
  if [[ -z "${VOICE_TYPE_TARGET_RATE:-}" && "$TARGET_RATE" -gt 48000 ]]; then TARGET_RATE=48000; fi
  TARGET_CHANNELS="${CHANNELS:-1}"
  TARGET_CODEC="$(codec_for_format "$TARGET_FORMAT")"
  api_out="${FILE}.api.wav"
  use_loudnorm="${VOICE_TYPE_LOUDNORM:-1}"  # allow disabling
  echo "prepare_api_audio: target_fmt=$TARGET_FORMAT codec=$TARGET_CODEC rate=$TARGET_RATE ch=$TARGET_CHANNELS loudnorm=$use_loudnorm" &>>"$LOGFILE"

  if [[ "$use_loudnorm" == "1" ]]; then # 1 pass loudnorm
    if ffmpeg -hide_banner -nostats -y -i "$FILE.wav" \
      -af "loudnorm=I=-23:LRA=7:TP=-2:linear=false:print_format=summary" \
      -ac "$TARGET_CHANNELS" -ar "$TARGET_RATE" -c:a "$TARGET_CODEC" "$api_out" &>>"$LOGFILE" 2>&1; then
      echo "prepare_api_audio: loudnorm dynamic complete -> $api_out" &>>"$LOGFILE"
    else
      echo "prepare_api_audio: loudnorm dynamic pass failed; will try plain conversion" &>>"$LOGFILE"
    fi
  fi

  if [[ "$use_loudnorm" == "2" ]]; then # 2 pass loudnorm (bit longer)
    loudnorm_pass1=$(ffmpeg -hide_banner -nostats -y -i "$FILE.wav" -af loudnorm=I=-23:LRA=7:TP=-2:print_format=json -f null - 2>&1 || true)
    loudnorm_json=$(awk 'BEGIN{capture=0} /^\{/ {capture=1} capture {print} /^\}/ {if(capture){capture=0}}' <<<"$loudnorm_pass1")
    if [[ -n "$loudnorm_json" ]]; then
      measured_I=$(jq -r '.input_i' <<<"$loudnorm_json" 2>/dev/null || true)
      measured_LRA=$(jq -r '.input_lra' <<<"$loudnorm_json" 2>/dev/null || true)
      measured_TP=$(jq -r '.input_tp' <<<"$loudnorm_json" 2>/dev/null || true)
      measured_thresh=$(jq -r '.input_thresh' <<<"$loudnorm_json" 2>/dev/null || true)
      offset=$(jq -r '.target_offset' <<<"$loudnorm_json" 2>/dev/null || true)
      if [[ -n "$measured_I" && "$measured_I" != "null" ]]; then
        if ffmpeg -hide_banner -nostats -y -i "$FILE.wav" \
          -af "loudnorm=I=-23:LRA=7:TP=-2:measured_I=$measured_I:measured_LRA=$measured_LRA:measured_TP=$measured_TP:measured_thresh=$measured_thresh:offset=$offset:linear=true:print_format=summary" \
          -ac "$TARGET_CHANNELS" -ar "$TARGET_RATE" -c:a "$TARGET_CODEC" "$api_out" &>>"$LOGFILE" 2>&1; then
          echo "prepare_api_audio: two-pass loudnorm complete -> $api_out (I=$measured_I LRA=$measured_LRA TP=$measured_TP)" &>>"$LOGFILE"
        else
          echo "prepare_api_audio: loudnorm second pass failed; will try plain conversion" &>>"$LOGFILE"
        fi
      else
        echo "prepare_api_audio: loudnorm metrics missing; skipping second pass" &>>"$LOGFILE"
      fi
    else
      echo "prepare_api_audio: loudnorm analysis produced no JSON; skipping normalization" &>>"$LOGFILE"
    fi
  fi

  if [[ ! -f "$api_out" ]]; then
    if ffmpeg -y -i "$FILE.wav" -ac "$TARGET_CHANNELS" -ar "$TARGET_RATE" -c:a "$TARGET_CODEC" "$api_out" &>>"$LOGFILE" 2>&1; then
      echo "prepare_api_audio: plain conversion done -> $api_out" &>>"$LOGFILE"
    else
      # Fallback: force S16_LE
      echo "prepare_api_audio: conversion to $TARGET_CODEC failed; falling back to pcm_s16le" &>>"$LOGFILE"
      if ffmpeg -y -i "$FILE.wav" -ac "$TARGET_CHANNELS" -ar "$TARGET_RATE" -c:a pcm_s16le "$api_out" &>>"$LOGFILE" 2>&1; then
        echo "prepare_api_audio: fallback to pcm_s16le succeeded" &>>"$LOGFILE"
        API_FORMAT="S16_LE"; TARGET_FORMAT="S16_LE"; TARGET_CODEC="pcm_s16le"
      else
        echo "prepare_api_audio: fallback conversion failed; using original" &>>"$LOGFILE"; return 1
      fi
    fi
  fi

  # Optional loudness verification (ebur128) if requested
  if [[ -f "$api_out" && "${VOICE_TYPE_VERIFY_LOUDNESS:-0}" == "1" ]]; then
    ffmpeg -hide_banner -nostats -i "$api_out" -filter_complex ebur128 -f null - 2>&1 | awk '/I:/ {print "prepare_api_audio: post-normalization " $0}' &>>"$LOGFILE" || true
  fi

  if [[ "${VOICE_TYPE_KEEP_ORIGINAL:-1}" == "0" && -f "$api_out" ]]; then
    mv "$api_out" "$FILE.wav" && echo "prepare_api_audio: replaced original with API copy (KEEP_ORIGINAL=0 final_codec=$TARGET_CODEC)" &>>"$LOGFILE"
  fi
}

# Restore original stop_recording function (critical)
stop_recording() {
  echo "Stopping recording..." &>>"$LOGFILE"
  if [[ -z "${PID:-}" ]]; then echo "No PID in session; nothing to stop." &>>"$LOGFILE"; return 0; fi
  if [[ ! -d "/proc/$PID" ]]; then echo "Process $PID not running; stale session." &>>"$LOGFILE"; return 0; fi
  if [[ -r "/proc/$PID/cmdline" ]]; then
    local cmdline
    cmdline=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)
    if [[ -n "$cmdline" && ! "$cmdline" =~ arecord ]]; then
      echo "Note: PID $PID cmdline does not look like arecord: $cmdline" &>>"$LOGFILE"
    fi
  fi
  kill "$PID" 2>/dev/null || true
  local waited=0 max_wait=50
  while kill -0 "$PID" 2>/dev/null; do
    if (( waited >= max_wait )); then
      echo "PID $PID did not exit after SIGTERM; sending SIGKILL..." &>>"$LOGFILE"
      kill -9 "$PID" 2>/dev/null || true
      break
    fi
    sleep 0.1; ((waited++))
  done
  if kill -0 "$PID" 2>/dev/null; then
    echo "Attempting killall arecord as fallback..." &>>"$LOGFILE"
    killall -q arecord || true
    sleep 0.2
  fi
  if kill -0 "$PID" 2>/dev/null; then
    echo "Warning: Failed to stop process $PID (stale)." &>>"$LOGFILE"
  else
    echo "Stopped recording (pid $PID)." &>>"$LOGFILE"
  fi
}

output_transcript() {
  if [[ -f "$FILE.txt" ]]; then
    perl -pi -e 'chomp if eof' "$FILE.txt" 2>/dev/null || true
    xclip -selection clipboard < "$FILE.txt" &>>"$LOGFILE" || true
    echo "Transcript copied to clipboard: $FILE.txt" &>>"$LOGFILE"
    notify "Transcription ready" "CTRL-V"
  else
    echo "Transcript file missing: $FILE.txt" &>>"$LOGFILE"
    notify "Transcription failed" "Transcript file missing: $FILE.txt"
  fi
}

transcribe_with_openai() {
  local src
  src="${FILE}.api.wav"
  [[ -f "$src" ]] || src="${FILE}.wav"
  if [[ ! -f "$src" ]]; then echo "Audio file not found: $src" &>>"$LOGFILE"; return 1; fi
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
  if [[ ! -f "$src" ]]; then echo "Audio file not found: $src" &>>"$LOGFILE"; return 1; fi
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
  if [[ -z "${DEEPGRAM_TOKEN:-}" ]]; then transcribe_with_openai || true; else transcribe_with_deepgram || true; fi
  set -u
}

cleanup_session() {
  rm -f "$SESSION_FILE" || true
  echo "cleanup_session: removed $SESSION_FILE" &>>"$LOGFILE"
}

main() {
  ensure_state_dirs
  sanity_check
  if ! acquire_lock; then exit 1; fi
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
      notify "Recording started" "Trigger again to stop"
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
