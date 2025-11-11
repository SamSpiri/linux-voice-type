https://blog.theodo.com/2023/11/speech-to-text-keyboard-button/

# Linux voice typing

## Install

```bash
sudo apt install xdotool jq curl arecord killall ffmpeg xclip -y
```

You will need to set up an openAI or Deepgram key and put it in the `~/.ai-token` file

```txt
DEEPGRAM_TOKEN=xxxx
OPEN_AI_TOKEN='sk-xxxx'
```

The script now probes your audio device and prefers high bit-depth formats for better transcription quality:
- 24-bit little endian (packed or 3-byte)
- 32-bit little endian
- 16-bit little endian (fallback)

It also persists the detected FORMAT, RATE, and CHANNELS in a session file so that the later normalization step (ffmpeg loudnorm) preserves the original bit depth, sample rate, and channel count instead of forcing a lower-quality 16-bit/22kHz conversion.

You can list recording devices with:

```bash
arecord -l
```


## Usage

Start the recording:

```bash
./voice-typing.sh
```

Stop the recording (transcribes and copies text to clipboard):

```bash
./voice-typing.sh
```

If `notify-send` is available you will get desktop notifications. Clipboard copy uses `xclip`.

### Notes
- Normalization uses two-pass EBU R128 loudnorm when possible; if metrics parsing fails, it falls back to a simple format-preserving conversion.
- Set `VOICE_TYPE_NO_NOTIFY=1` to disable notifications.
- Requires either `DEEPGRAM_TOKEN` or `OPEN_AI_TOKEN` in your environment/config.
