# Where this stands — 2026-09-04

Working notes for picking the project back up. `README.md` explains how the
thing works, `docs/LOCAL-FIRST-PLAN.md` explains why it works this way and
carries every measurement; this file is what is true right now.

## It runs entirely on this Mac, for nothing

Recording a meeting no longer costs money, uploads anything, or needs an
account. Measured end to end on a real 111-minute meeting, not on fixtures.

| Piece | State |
|---|---|
| Mac app | `/Applications/Scribe.app`, signed, 📝 icon |
| iPhone app | installed and signed; installs over Wi-Fi |
| Transcription | **Apple `SpeechAnalyzer`** — 56× realtime, 5% CPU, $0 |
| Speakers | **FluidAudio offline diarizer** — one pass, no seams |
| Summaries | **Apple `FoundationModels`** — ~5 min at 2% CPU, $0 |
| Storage | **`~/Library/Application Support/Scribe/scribe.sqlite`** |
| Gemini | still selectable, for languages the device cannot do |
| Notion export | works, opt-in |
| MCP (stdio) | works against hosted Supabase via `.env` |

Costs, against what the same meeting used to cost:

| | Before | Now |
|---|---|---|
| Transcription | ~35 min paced, $1.30 | 119 s, $0 |
| Speakers | 8 found for 4 people | matches reality |
| Summary | uploaded to Google, $0.006 | on device, $0 |

## The one thing still weak

**The narrative summary.** Across four runs on the same meeting the title was
right every time and the extracted decisions/actions/questions were useful, but
the two-sentence overview swung between listing items the reader is already
shown and saying nothing at all. A 3B model with a 4096-token window reading one
passage at a time cannot reliably tell a decision from a strong opinion, and no
prompt makes it deterministic. Decision counts across those runs: 19, 9, 2, 1.

Trust the title and the lists. For a meeting where the narrative matters, switch
Settings → Summaries to a local server (Ollama, LM Studio) — a 4B model holds the
whole transcript at once. That path is tested against a stand-in server but has
never been run against a real Ollama.

## Things that are easy to get wrong

- **Do not back up `scribe.sqlite` by copying it.** Write-ahead logging keeps
  recent meetings in `scribe.sqlite-wal`; a plain copy silently leaves them
  behind, which is exactly what happened here once. Use Settings → **Back up…**,
  which does `vacuum into`.
- **Never pin diarization to the attendee roster.** It looks like evidence and
  is a guess — a roster that over-states forces the clusterer to split someone
  in two, which is the over-counting bug this design exists to avoid. Only live
  tags are evidence, because a tap means somebody was observed speaking.
- **Never put a worked example in a model prompt.** When the reduce prompt
  overflowed, the model returned the example from its own instructions as the
  answer: a meeting about vehicle inventory came back titled "Q4 migration
  timing".
- `./scripts/install-mac.sh` and `./scripts/install-iphone.sh` do the whole
  build-and-install. Do not hand-edit anything inside a signed bundle.
- `apps/Local.xcconfig` holds the Apple team id and is gitignored.
- Run `xcodegen generate` in `apps/` after adding a source file.
- Deployment target is macOS/iOS 26 — `SpeechAnalyzer` and `FoundationModels`
  need it. ScribeCore needs swift-tools-version 6.2 to declare `.v26`.

## Hosted Supabase — still there, no longer used by the apps

Project `machina-scribe` / `lclnwhbhoibnipcbgbpi`, us-west-2, schema current. The
apps read SQLite now; this remains as the MCP server's backend and as a copy of
the original data. `scripts/import-from-supabase.py` moves a hosted project into
the local file.

## Next, roughly in order

1. **Record a fresh meeting on the new pipeline.** Everything above was measured
   by replaying one existing recording; nothing has been captured live through
   the local path yet.
2. Try a real Ollama against Settings → Summaries → Local server. Only a
   stand-in has been exercised.
3. System audio on the Mac via `ScreenCaptureKit`, kept as a second stream so
   "you said" and "they said" never mix. This is what makes remote calls work.
4. The Humla-inspired UI work in `docs/LOCAL-FIRST-PLAN.md` — inset cards on a
   canvas, one typeface and accent, speaker dots in a gutter.
5. Deploy the remote MCP Worker if phone access to transcripts matters.
6. Rotate the Gemini key — it appeared in a session transcript.
