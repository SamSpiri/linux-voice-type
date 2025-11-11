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

readonly PREFERRED_FORMATS=(S16_LE S24_LE S24_3LE S32_LE)
readonly PREFERRED_RATES=(16000 44100 48000 32000)
readonly PREFERRED_CHANNELS=(1 2)

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
    echo "FORMAT=S16_LE RATE=16000 CHANNELS=1"
    echo "FORMAT=S16_LE RATE=16000 CHANNELS=1" &>>"$LOGFILE"
    return
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
  # Print to stdout for callers (e.g. params=$(probe_params ...)) and also append to the logfile
  echo "FORMAT=$chosen_format RATE=$chosen_rate CHANNELS=$chosen_channels"
  echo "FORMAT=$chosen_format RATE=$chosen_rate CHANNELS=$chosen_channels" &>>"$LOGFILE"
}

start_recording() {
  ensure_state_dirs
  # Pick a new timestamped file only for a new session
  FILE="${HOME}/.local/var/voice-type/recording-$(date +%Y%m%d-%H%M%S)"
  # switch logging to the per-session logfile
  LOGFILE="${FILE}.log"
  local dev params FORMAT RATE CHANNELS
  dev=$(detect_default_device)
  params=$(probe_params "$dev")
  eval "$params"  # sets FORMAT RATE CHANNELS
  echo "Recording from device '$dev' format=$FORMAT rate=$RATE channels=$CHANNELS" &>>"$LOGFILE"
  set -x
  nohup arecord -D "$dev" -f "$FORMAT" -r "$RATE" -c "$CHANNELS" "$FILE.wav" --duration="$MAX_DURATION" &>>"$FILE.arecord.log" &
  PID=$!
  set +x
  # Initialize / append to session file
  : > "$SESSION_FILE"
  echo "FILE=$FILE" >> "$SESSION_FILE"
  echo "PID=$PID" >> "$SESSION_FILE"
  echo "Started session: FILE=$FILE PID=$PID" &>>"$LOGFILE"
}

normalize_audio() {
  # Two-pass loudness + format normalization using ffmpeg loudnorm
  # Result: 16 kHz, mono, s16, LUFS normalized around -23 LUFS (broadcast standard) unless overridden later.
  if command -v ffmpeg &>/dev/null && [[ -f "$FILE.wav" ]]; then
    echo "normalize_audio: starting two-pass loudnorm for $FILE.wav" &>>"$LOGFILE"
    local pass1_output pass1_json measured_I measured_LRA measured_TP measured_thresh offset
    # First pass: analyze loudness
    pass1_output=$(ffmpeg -hide_banner -nostats -y -i "$FILE.wav" -af loudnorm=I=-23:LRA=7:TP=-2:print_format=json -f null - 2>&1 || true)
    # Extract JSON object produced by loudnorm
    pass1_json=$(awk 'BEGIN{capture=0} /^\{/ {capture=1} capture {print} /^\}/ {if(capture){capture=0}}' <<<"$pass1_output")
    if [[ -n "$pass1_json" ]]; then
      # Parse required measured values with jq (dependency already checked in sanity_check)
      measured_I=$(jq -r '.input_i' <<<"$pass1_json" 2>/dev/null || true)
      measured_LRA=$(jq -r '.input_lra' <<<"$pass1_json" 2>/dev/null || true)
      measured_TP=$(jq -r '.input_tp' <<<"$pass1_json" 2>/dev/null || true)
      measured_thresh=$(jq -r '.input_thresh' <<<"$pass1_json" 2>/dev/null || true)
      offset=$(jq -r '.target_offset' <<<"$pass1_json" 2>/dev/null || true)
      if [[ -n "$measured_I" && -n "$measured_LRA" && -n "$measured_TP" && -n "$measured_thresh" && -n "$offset" && "$measured_I" != "null" ]]; then
        echo "normalize_audio: pass1 metrics input_i=$measured_I input_lra=$measured_LRA input_tp=$measured_TP input_thresh=$measured_thresh offset=$offset" &>>"$LOGFILE"
        # Second pass: apply normalization with measured values; also enforce target format.
        if ffmpeg -hide_banner -nostats -y -i "$FILE.wav" -af "loudnorm=I=-23:LRA=7:TP=-2:measured_I=$measured_I:measured_LRA=$measured_LRA:measured_TP=$measured_TP:measured_thresh=$measured_thresh:offset=$offset:linear=true:print_format=summary" -ac 1 -ar 16000 -sample_fmt s16 "${FILE}-norm.wav" &>>"$LOGFILE" 2>&1; then
          mv "${FILE}-norm.wav" "$FILE.wav"
          echo "normalize_audio: two-pass loudnorm complete (file normalized)" &>>"$LOGFILE"
          return 0
        else
          echo "normalize_audio: second pass failed; falling back to simple format normalization" &>>"$LOGFILE"
        fi
      else
        echo "normalize_audio: could not parse loudnorm JSON metrics; falling back" &>>"$LOGFILE"
      fi
    else
      echo "normalize_audio: loudnorm analysis produced no JSON; falling back" &>>"$LOGFILE"
    fi
    # Fallback: simple format conversion only
    if ffmpeg -y -i "$FILE.wav" -ac 1 -ar 16000 -sample_fmt s16 "${FILE}-norm.wav" &>>"$LOGFILE" 2>&1; then
      mv "${FILE}-norm.wav" "$FILE.wav"
      echo "normalize_audio: fallback format normalization done" &>>"$LOGFILE"
    else
      echo "normalize_audio: fallback ffmpeg resample failed" &>>"$LOGFILE"
    fi
  else
    echo "normalize_audio: ffmpeg not available or file missing; skipping" &>>"$LOGFILE"
  fi
}

stop_recording() {
  echo "Stopping recording..." &>>"$LOGFILE"
  if [[ -z "${PID:-}" ]]; then
    echo "No PID in session; nothing to stop." &>>"$LOGFILE"
    return 0
  fi
  # If process doesn't exist, treat as stale
  if [[ ! -d "/proc/$PID" ]]; then
    echo "Process $PID not running; stale session." &>>"$LOGFILE"
    return 0
  fi
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
    perl -pi -e 'chomp if eof' "$FILE.txt"
    xclip -selection clipboard < "$FILE.txt" &>>"$LOGFILE" || true
    echo "Transcript copied to clipboard: $FILE.txt" &>>"$LOGFILE"
    notify "Transcription ready" "CTRL-V"
  else
    echo "Transcript file missing: $FILE.txt" &>>"$LOGFILE"
    notify "Transcription failed" "Transcript file missing: $FILE.txt"
  fi
}

transcribe_with_openai() {
  if [[ ! -f "$FILE.wav" ]]; then
    echo "Audio file not found: $FILE.wav" &>>"$LOGFILE"
    return 1
  fi
  curl --fail --request POST \
    --url https://api.openai.com/v1/audio/transcriptions \
    --header "Authorization: Bearer $OPEN_AI_TOKEN" \
    --header 'Content-Type: multipart/form-data' \
    --form file="@$FILE.wav" \
    --form model=whisper-1 \
    --form response_format=text \
    -o "${FILE}.txt" &>>"$LOGFILE"
  echo "transcribe_with_openai: request finished (output ${FILE}.txt)" &>>"$LOGFILE"
}

transcribe_with_deepgram() {
  if [[ ! -f "$FILE.wav" ]]; then
    echo "Audio file not found: $FILE.wav";
    echo "Audio file not found: $FILE.wav" &>>"$LOGFILE"
    return 1
  fi
  DPARAMS="model=nova-3-general&smart_format=true&detect_language=true"
  curl --fail --request POST \
    --url "https://api.deepgram.com/v1/listen?${DPARAMS}" \
    --header "Authorization: Token $DEEPGRAM_TOKEN" \
    --header 'Content-Type: audio/wav' \
    --data-binary "@$FILE.wav" \
    -o "${FILE}.json" &>>"$LOGFILE"
  echo "transcribe_with_deepgram: request finished (output ${FILE}.json)" &>>"$LOGFILE"
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
    # lock acquisition failure already notified; exit
    exit 1
  fi
  # Ensure lock released no matter what
  trap release_lock EXIT
  if [[ -f "$SESSION_FILE" ]]; then
    # Second invocation: load session, stop and transcribe
    # shellcheck disable=SC1090
    source "$SESSION_FILE" || true
    if [[ -z "${FILE:-}" ]]; then
      echo "Session file missing FILE variable; aborting." &>>"$LOGFILE"
      cleanup_session
      notify "Voice typing error" "Session corrupt"
      exit 1
    fi
    # ensure per-session logfile if FILE was set from session file
    LOGFILE="${FILE}.log"
    stop_recording || true
    normalize_audio || true
    transcript || true
    output_transcript || true
    cleanup_session
  else
    # First invocation: start new recording
    start_recording
    notify "Recording started" "Run again to stop"
  fi
}

main
