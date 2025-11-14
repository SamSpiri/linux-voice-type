#!/usr/bin/env bash
# usage: exec ./voice-typing.sh twice to start and stop recording
# Dependencies: curl, jq, arecord, ffmpeg, xdotool, killall, flock, xclip, perl, yad
# Simplified streaming pipeline: arecord | ffmpeg (silence removal + loudnorm)

set -euo pipefail
IFS=$'\n\t'

###############################################
# Configuration (defaults - can be overridden) #
###############################################
# State and output locations
readonly VOICE_TYPE_STATE_DIR="${HOME}/.local/state/voice-type"
readonly VOICE_TYPE_VAR_DIR="${HOME}/.local/var/voice-type"
readonly SESSION_FILE="${VOICE_TYPE_STATE_DIR}/session.env"
readonly LOCK_FILE="${VOICE_TYPE_STATE_DIR}/lock"
readonly DEFAULT_LOGFILE="${VOICE_TYPE_VAR_DIR}/voice-type.log"
readonly TRAY_FIFO="${VOICE_TYPE_STATE_DIR}/tray.fifo"
readonly TRAY_PID_FILE="${VOICE_TYPE_STATE_DIR}/tray.pid"

KEEP_TRAY_ON_EXIT=0

# Recording parameters (fixed simplified format)
: "${VOICE_TYPE_DEVICE:=default}"           # ALSA device (arecord -D)
: "${VOICE_TYPE_FORMAT_REC:=S32_LE}"        # arecord sample format (raw) - will be mapped for ffmpeg (-f)
: "${VOICE_TYPE_RATE_REC:=44100}"           # arecord sample rate Hz (input)
: "${VOICE_TYPE_RATE:=44100}"               # target/output sample rate Hz (resample if different)
: "${VOICE_TYPE_CHANNELS:=1}"               # channels (mono)
: "${VOICE_TYPE_MAX_DURATION:=3600}"        # safety cap seconds

# Silence removal defaults (from experimental command)
: "${VOICE_TYPE_SILENCE_ENABLE:=1}"          # set 0 to disable silenceremove
: "${VOICE_TYPE_SILENCE_THRESHOLD_DB:=54}"   # numeric dB value (will be used as -${value}dB)
: "${VOICE_TYPE_SILENCE_START:=1}"           # start_silence seconds
: "${VOICE_TYPE_SILENCE_STOP:=1}"            # stop_silence seconds
: "${VOICE_TYPE_SILENCE_START_PERIODS:=1}"   # start_periods
: "${VOICE_TYPE_SILENCE_STOP_PERIODS:=-1}"   # stop_periods

# Loudnorm defaults (from experimental command)
: "${VOICE_TYPE_LOUDNORM_ENABLE:=1}"         # set 0 to disable loudnorm
: "${VOICE_TYPE_LOUDNORM_I:=-23}"            # Integrated loudness target
: "${VOICE_TYPE_LOUDNORM_LRA:=7}"            # Loudness range target
: "${VOICE_TYPE_LOUDNORM_TP:=-2}"            # True peak target
: "${VOICE_TYPE_LOUDNORM_LINEAR:=false}"     # linear=false

# Notifications
: "${VOICE_TYPE_NO_NOTIFY:=0}"               # 1 disables notifications
: "${VOICE_TYPE_TRAY_ICON:=1}"               # 1 enables tray icon (set 0 to disable)

# Output encoding (added)
: "${VOICE_TYPE_AUDIO_CODEC:=mp3}"          # target audio codec (mp3 for libmp3lame; wav for pcm_s16le)
: "${VOICE_TYPE_MP3_BITRATE:=96k}"          # mp3 bitrate if mp3 selected

# API tokens (must have at least one)
# Source user config AFTER defaults to allow overrides
if [[ -f "${HOME}/.config/linux-voice-type" ]]; then
  # Ensure restrictive permissions recommended externally
  # shellcheck source=/dev/null
  source "${HOME}/.config/linux-voice-type"
fi

# Variables set per session
FILE=""               # base file path without extension
ARECORD_PID=""        # PID of arecord writer
FFMPEG_PID=""         # PID of ffmpeg consumer
FIFO=""               # FIFO path
LOGFILE="$DEFAULT_LOGFILE"
LOCK_FD=0
AUDIO_EXT=""          # derived extension based on codec
AUDIO_FILE=""         # full path to audio file
TRAY_PID=""           # PID of yad tray process

#################################
# Utility / infrastructure funcs #
#################################
notify() {
  if [[ "$VOICE_TYPE_NO_NOTIFY" == "1" ]]; then return 0; fi
  if command -v notify-send &>/dev/null; then
    local title="$1" body="${2:-}"
    notify-send --app-name="VoiceType" --icon=audio-input-microphone "$title" "$body" || true
    echo "notify: $title $body" &>>"$LOGFILE"
  fi
}

ensure_state_dirs() {
  mkdir -p "$VOICE_TYPE_STATE_DIR" || true
  mkdir -p "$VOICE_TYPE_VAR_DIR" || true
}

#################################
# Tray icon management functions #
#################################
start_tray_icon() {
  if [[ "$VOICE_TYPE_TRAY_ICON" != "1" ]]; then return 0; fi
  if ! command -v yad &>/dev/null; then
    echo "yad not found; tray icon disabled" &>>"$LOGFILE"
    return 0
  fi

  # Clean up any existing tray
  stop_tray_icon 2>/dev/null || true

  # Create FIFO for communication
  rm -f "$TRAY_FIFO" 2>/dev/null || true
  mkfifo "$TRAY_FIFO" 2>/dev/null || true

  # Start yad notification icon in background
  yad --notification \
    --listen \
    --image="audio-input-microphone" \
    --text="Voice Typing: Idle" \
    --no-middle \
    --command="" \
    <"$TRAY_FIFO" &>/dev/null &

  TRAY_PID=$!
  echo "$TRAY_PID" > "$TRAY_PID_FILE"

  echo "start_tray_icon: started yad tray (PID=$TRAY_PID)" &>>"$LOGFILE"

  # Keep FIFO open for writing
  exec 3>"$TRAY_FIFO"
}

stop_tray_icon() {
  if [[ "$VOICE_TYPE_TRAY_ICON" != "1" ]]; then return 0; fi
  if [[ "$KEEP_TRAY_ON_EXIT" != "0" ]]; then return 0; fi

  # Close FIFO descriptor if open
  exec 3>&- 2>/dev/null || true

  # Kill yad process
  if [[ -f "$TRAY_PID_FILE" ]]; then
    local pid
    pid=$(cat "$TRAY_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && [[ -d "/proc/$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      echo "stop_tray_icon: killed yad tray (PID=$pid)" &>>"$LOGFILE"
    fi
    rm -f "$TRAY_PID_FILE" 2>/dev/null || true
  fi

  # Cleanup FIFO
  rm -f "$TRAY_FIFO" 2>/dev/null || true
}

update_tray_icon() {
  if [[ "$VOICE_TYPE_TRAY_ICON" != "1" ]]; then return 0; fi
  if [[ ! -p "$TRAY_FIFO" ]]; then return 0; fi

  local state="$1"
  local icon tooltip

  case "$state" in
    recording)
      icon="media-record"
      tooltip="Voice Typing: Recording..."
      ;;
    processing)
      icon="emblem-synchronizing"
      tooltip="Voice Typing: Processing..."
      ;;
    error)
      icon="dialog-error"
      tooltip="Voice Typing: Error"
      ;;
    idle|*)
      icon="audio-input-microphone"
      tooltip="Voice Typing: Idle"
      ;;
  esac

  echo "icon:$icon" >&3 2>/dev/null || true
  echo "tooltip:$tooltip" >&3 2>/dev/null || true

  echo "update_tray_icon: state=$state icon=$icon" &>>"$LOGFILE"
}

#################################
# Recording functions           #
#################################
# Helper: map ALSA format string to ffmpeg raw format name
ffmpeg_raw_format_from_arecord() {
  case "${VOICE_TYPE_FORMAT_REC}" in
    S32_LE) echo s32le ;;
    S24_LE) echo s24le ;;
    S16_LE) echo s16le ;;
    F32_LE) echo f32le ;;
    *) echo s16le ;; # safe default
  esac
}

start_recording_stream() {
  ensure_state_dirs
  FILE="${VOICE_TYPE_VAR_DIR}/recording-$(date +%Y%m%d-%H%M%S)"
  LOGFILE="${FILE}.log"
  FIFO="${FILE}.pipe"
  if [[ "$VOICE_TYPE_AUDIO_CODEC" == "mp3" ]]; then AUDIO_EXT="mp3"; else AUDIO_EXT="wav"; fi
  AUDIO_FILE="${FILE}.${AUDIO_EXT}"
  mkfifo "$FIFO"

  ps xa | grep arecord | grep "$VOICE_TYPE_STATE_DIR" | awk '{system("kill "$1)}' || true

  local filter_chain
  local filters="" silent_thresh="-${VOICE_TYPE_SILENCE_THRESHOLD_DB}dB"
  if [[ "$VOICE_TYPE_SILENCE_ENABLE" == "1" ]]; then
    filters+="silenceremove=start_periods=${VOICE_TYPE_SILENCE_START_PERIODS}:start_silence=${VOICE_TYPE_SILENCE_START}:start_threshold=${silent_thresh}:stop_periods=${VOICE_TYPE_SILENCE_STOP_PERIODS}:stop_silence=${VOICE_TYPE_SILENCE_STOP}:stop_threshold=${silent_thresh}"
  fi
  if [[ "$VOICE_TYPE_LOUDNORM_ENABLE" == "1" ]]; then
    [[ -n "$filters" ]] && filters+="," # separator
    filters+="loudnorm=I=${VOICE_TYPE_LOUDNORM_I}:LRA=${VOICE_TYPE_LOUDNORM_LRA}:TP=${VOICE_TYPE_LOUDNORM_TP}:linear=${VOICE_TYPE_LOUDNORM_LINEAR}:print_format=summary"
  fi
  if [[ -n "$filters" ]]; then
    filter_chain=(-af "$filters")
  fi

  local ff_raw_format
  ff_raw_format="$(ffmpeg_raw_format_from_arecord)"

  update_tray_icon "processing"

  echo "start_recording_stream: device=$VOICE_TYPE_DEVICE arecord_format=$VOICE_TYPE_FORMAT_REC ffmpeg_raw=$ff_raw_format in_rate=$VOICE_TYPE_RATE_REC out_rate=$VOICE_TYPE_RATE ch=$VOICE_TYPE_CHANNELS filters='${filters:-none}' codec=$VOICE_TYPE_AUDIO_CODEC" &>>"$LOGFILE"

  # Start arecord producer (raw format to FIFO)
  arecord -D "$VOICE_TYPE_DEVICE" -f "$VOICE_TYPE_FORMAT_REC" -r "$VOICE_TYPE_RATE_REC" -c "$VOICE_TYPE_CHANNELS" -t raw --duration "$VOICE_TYPE_MAX_DURATION" "$FIFO" &>>"$LOGFILE" 2>&1 &
  ARECORD_PID=$!
  # Start ffmpeg consumer. Input uses raw format & input rate; output optionally resamples if VOICE_TYPE_RATE differs.
  local output_rate_args=()
  if [[ "$VOICE_TYPE_RATE" != "$VOICE_TYPE_RATE_REC" ]]; then
    output_rate_args=(-ar "$VOICE_TYPE_RATE")
  fi
  if [[ "$VOICE_TYPE_AUDIO_CODEC" == "mp3" ]]; then
    ffmpeg -hide_banner -nostats -y \
      -f "$ff_raw_format" -ar "$VOICE_TYPE_RATE_REC" -ac "$VOICE_TYPE_CHANNELS" -i "$FIFO" \
      "${filter_chain[@]}" \
      -ac "$VOICE_TYPE_CHANNELS" "${output_rate_args[@]}" \
      -c:a libmp3lame -b:a "$VOICE_TYPE_MP3_BITRATE" "$AUDIO_FILE" &>>"$LOGFILE" 2>&1 &
  else
    ffmpeg -hide_banner -nostats -y \
      -f "$ff_raw_format" -ar "$VOICE_TYPE_RATE_REC" -ac "$VOICE_TYPE_CHANNELS" -i "$FIFO" \
      "${filter_chain[@]}" \
      -ac "$VOICE_TYPE_CHANNELS" "${output_rate_args[@]}" \
      -c:a pcm_s16le "$AUDIO_FILE" &>>"$LOGFILE" 2>&1 &
  fi
  FFMPEG_PID=$!

  # Persist session state
  : >"$SESSION_FILE"
  {
    echo "FILE=$FILE"; echo "ARECORD_PID=$ARECORD_PID"; echo "FFMPEG_PID=$FFMPEG_PID"; echo "FIFO=$FIFO"; echo "AUDIO_FILE=$AUDIO_FILE"; echo "AUDIO_EXT=$AUDIO_EXT";
  } >>"$SESSION_FILE"
  echo "Started session: FILE=$FILE ARECORD_PID=$ARECORD_PID FFMPEG_PID=$FFMPEG_PID FIFO=$FIFO" &>>"$LOGFILE"

  # Wait for output wav file creation (notify only after present with data)
  for i in {1..80}; do
    if [[ -f "$AUDIO_FILE" ]]; then
      echo "Output file created after $i * 0.1s" &>>"$LOGFILE"
      break
    fi
    sleep 0.1
  done

  # Update tray to recording state
  update_tray_icon "recording"
}

stop_recording_stream() {
  echo "stop_recording_stream: stopping (ARECORD_PID=${ARECORD_PID:-} FFMPEG_PID=${FFMPEG_PID:-})" &>>"$LOGFILE"
  update_tray_icon "processing"
  if [[ -z "${ARECORD_PID:-}" ]]; then echo "No ARECORD_PID in session; abort" &>>"$LOGFILE"; return 0; fi
  if [[ -d "/proc/$ARECORD_PID" ]]; then
    kill "$ARECORD_PID" 2>/dev/null || true
  fi
  local waited=0 max_wait=100
  while [[ -d "/proc/${FFMPEG_PID:-}" ]]; do
    if (( waited >= max_wait )); then
      echo "ffmpeg PID $FFMPEG_PID still running after timeout; sending SIGTERM" &>>"$LOGFILE"
      kill "$FFMPEG_PID" 2>/dev/null || true
      break
    fi
    sleep 0.1; ((waited++))
  done
  if [[ -d "/proc/${FFMPEG_PID:-}" ]]; then
    echo "Warning: ffmpeg did not exit cleanly (PID=$FFMPEG_PID)" &>>"$LOGFILE"
  else
    echo "Pipeline stopped (arecord $ARECORD_PID, ffmpeg $FFMPEG_PID)." &>>"$LOGFILE"
  fi
  ps xa | grep arecord | grep "$VOICE_TYPE_STATE_DIR" | awk '{system("kill "$1)}' || true
  # Cleanup FIFO
  [[ -n "$FIFO" && -p "$FIFO" ]] && rm -f "$FIFO" 2>/dev/null || true
}

output_transcript() {
  if [[ -f "$FILE.txt" ]]; then
    perl -pi -e 'chomp if eof' "$FILE.txt" 2>/dev/null || true
    xclip -selection clipboard < "$FILE.txt" &>>"$LOGFILE" || true
    echo "Transcript copied to clipboard: $FILE.txt" &>>"$LOGFILE"
    notify "Transcription ready" "CTRL-V"
  else
    echo "Transcript file missing: $FILE.txt" &>>"$LOGFILE"
    notify "Transcription failed" "Transcript missing"
  fi
}

transcribe_with_openai() {
  local src
  src="$AUDIO_FILE"
  if [[ ! -f "$src" ]]; then
    echo "Audio file not found: $src" &>>"$LOGFILE"
    update_tray_icon "error"
    return 1
  fi
  # OpenAI Whisper accepts mp3 or wav transparently
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
  src="$AUDIO_FILE"
  if [[ ! -f "$src" ]]; then
    echo "Audio file not found: $src" &>>"$LOGFILE"
    update_tray_icon "error"
    return 1
  fi
  local DPARAMS="model=nova-3-general&smart_format=true&detect_language=ru&detect_language=en&detect_language=de"
  local ctype
  if [[ "$AUDIO_EXT" == "mp3" ]]; then ctype="audio/mpeg"; else ctype="audio/wav"; fi
  echo curl --fail --request POST \
    --url "https://api.deepgram.com/v1/listen?${DPARAMS}" \
    --header "Authorization: Token $DEEPGRAM_TOKEN" \
    --header "Content-Type: $ctype" \
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
    transcribe_with_openai || { update_tray_icon "error"; return 1; }
  else
    transcribe_with_deepgram || { update_tray_icon "error"; return 1; }
  fi
  set -u
}

cleanup_session() {
  rm -f "$SESSION_FILE" || true
  echo "cleanup_session: removed $SESSION_FILE" &>>"$LOGFILE"
}

main() {
  ensure_state_dirs
  #sanity_check
  #if ! acquire_lock; then exit 1; fi
  #trap 'release_lock; stop_tray_icon' EXIT
  trap 'stop_tray_icon' EXIT

  # Start tray icon if not already running
  if [[ ! -f "$TRAY_PID_FILE" ]] || ! kill -0 "$(cat "$TRAY_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    start_tray_icon
    update_tray_icon "idle"
  fi

  if [[ -f "$SESSION_FILE" ]]; then
    # Stop phase
    # shellcheck source=/dev/null
    source "$SESSION_FILE" || true
    if [[ -z "${FILE:-}" ]]; then
      echo "Session file missing FILE variable; aborting." &>>"$LOGFILE"
      cleanup_session
      notify "Voice typing error" "Session corrupt"
      update_tray_icon "error"
      exit 1
    fi
    LOGFILE="${FILE}.log"
    # If arecord already gone but audio file not present treat as new
    if [[ ! -d "/proc/${ARECORD_PID:-}" && ! -f "$AUDIO_FILE" ]]; then
      echo "Fallback: no arecord process and no audio file; starting new recording instead." &>>"$LOGFILE"
      cleanup_session
      start_recording_stream
      notify "Recording started" "Trigger again to stop"
      return
    fi

    notify "Stopping recording" "Avoid using clipboard"
    stop_recording_stream || true
    transcript || { update_tray_icon "error"; }
    output_transcript || true
    cleanup_session
    update_tray_icon "idle"
  else
    start_recording_stream
    if [[ -f "$AUDIO_FILE" ]]; then
      notify "Recording started" "Trigger again to stop"
    else
      notify "Recording starting" "Please wait..."
    fi
    KEEP_TRAY_ON_EXIT=1
  fi
}

main
