# podcast-tts

Polish text in, MP3 in Wojtek's cloned voice out. Chatterbox Multilingual v3 on MLX
(`mlx-audio`), one chunk at a time, resumable.

Built as a factory work order (GUL-1749); this README records the first live run (GUL-1750).

## Run it

```bash
V=~/Projects/podcast-episodes/tts-bakeoff/.venv-mlx/bin/python3   # any venv with mlx-audio
$V podcast_tts.py \
  --config ~/.config/homelab/podcast-tts.toml \
  --in  ~/Projects/podcast-episodes/smartfony-na-kolkach-pl.txt \
  --out ~/Projects/podcast-episodes/smartfony-na-kolkach-wojtek-v2.mp3 \
  --work-dir ~/Projects/podcast-episodes/work-v2
```

The config and the respelling dictionary live outside the repo:

```bash
cp config.example.toml ~/.config/homelab/podcast-tts.toml
cp respell.toml       ~/.config/homelab/respell.toml
```

`--work-dir` holds `NNNN.wav` per chunk plus `manifest.json`. Re-running the same command
resumes: chunks marked `done` are skipped, so a crash costs one chunk, not the episode.
The summary JSON at the end carries `audio_seconds`, `generation_seconds` and the real-time
factor.

## Measured: first live run (M1 Air, 16 GB, 2026-11-22)

| | |
|---|---|
| source | `smartfony-na-kolkach-pl.txt`, 22 168 chars, 101 chunks |
| audio | 22.75 min (1364.8 s), MP3 21.8 MB |
| synthesis | 84 min of GPU time (5046 s, from `manifest.json`) |
| real-time factor | 3.83× real time |
| wall clock | ~2 h, including two `rc=137` kills and restarts |
| shortest chunk | 2.4 s (floor is 0.5 s, none below it) |
| longest silence | 0.0 s at −40 dB (silencedetect, no gap over 1 s) |
| peak footprint | 9.3 GB (3.2 GB resident) — macOS jetsam killed it |
| disk | ~38 MB of chunk WAVs + 21.8 MB MP3 |

Rough rule: **a 22-minute episode costs about 85 minutes of GPU time and ~10 GB of footprint
headroom on a 16 GB M1 Air.** No service, no API key, no cloud TTS.

## Gotchas from that run

- **Free disk, not RAM, is the constraint.** `rc=137` came back twice with RAM looking fine
  (`memory free 89%`). `df` said 443 MB free on a data volume pinned at 100 %, so macOS could not
  grow swap and jetsam shot the largest process — the engine, at 9.3 GB compressed. Freeing
  ~3.3 GB (uv cache, leftover bake-off models) ended the kills. Check `df` before blaming the
  model.
- **Kill it yourself before the kernel does.** A retry loop that reloads a 3 GB model into a
  squeezed machine gets killed again within two minutes. The ops driver watches RSS and stops the
  engine between chunks, so resume works from a known state.
- **The digit guard is not decoration.** `V2X` (vehicle-to-everything) survived normalisation
  as a digit, and `DigitInChunkError` aborted the run before the model loaded. Fix is one line
  in `respell.toml` (`"V2X" = "wi dwa iks"`), then re-run — the guard is what stops a chunk of
  numbers being read out character by character.
- **One line per respelling, checked by ear.** Add a `[phrases]` or `[words]` entry, regenerate
  only the affected chunks (the manifest redoes changed text), listen, keep or drop.
- **`nohup` alone is not enough** in a non-interactive shell here (`can't detach from console`);
  run the driver under the agent's background session, or a real LaunchDaemon if it must
  survive a reboot.
- **Listen without ears: `mlx-whisper`, not `faster-whisper`.** The ASR venv on this box was
  broken (`open() got an unexpected keyword argument 'metadata_errors'`); `uv pip install
  mlx-whisper` into the MLX venv and `mlx_whisper.transcribe(..., language="pl")` transcribed
  three 60 s windows in 49 s total. Word-overlap against the source text was 0.92 mean — the
  audio says what the article says.
- **Uploading to Mattermost: use curl.** A hand-rolled `urllib` multipart body is rejected by
  Mattermost 11 with `400 api.context.invalid_body_param.app_error` ("Invalid or missing filename
  in request body"), even though the file part carries a filename. `curl -F files=@…` uploads the
  same file fine. Cloudflare in front also needs a real `User-Agent`, else `403`.

## Files

- `podcast_tts.py` — chunker, normaliser, engine wrapper, assembler (two-pass loudnorm)
- `pl_norm.py` — Polish text normalisation, including the digit guard
- `respell.toml` — ear-checked respellings, applied before/after the numeric pass
- `config.example.toml` — profile, engine, chunk size, voice reference
- `tests/` — unit tests with a fake engine, no model download
