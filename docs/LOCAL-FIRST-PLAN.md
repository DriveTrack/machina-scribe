# Going fully local — plan

Written 2026-09-04, after reading [Humla](https://github.com/michaelwilhelmsen/humla)
end to end and measuring the candidate models on the target machine (M1 Pro,
16 GB, macOS 26.2).

The goal: Scribe costs nothing to run, sends no audio anywhere, and still feels
like Humla does — which is to say, seamless.

---

## What changed under us

Today's pipeline exists to work around Gemini. Gemini diarizes at most 30
minutes, so we cut long recordings into overlapping 27-minute chunks and stitch
the speaker labels back together across the seams. Everything painful about the
app grows out of that one constraint:

| What we built | Why | What it costs |
|---|---|---|
| `AudioChunker` — 27 min chunks, 2 min overlap | Gemini's 30-min diarization cap | export churn, seams |
| `Stitching.swift` — label matching across seams | chunks diarize independently | **speaker fragmentation** — 111 min / 3 people came back as 8 speakers |
| `ChunkCache` | a failed part must not redo the finished ones | extra state to get wrong |
| 45 s pacing + `retryDelay` backoff | six 38k-token requests exhaust tokens/minute | a 111-min meeting takes longer to transcribe than to hold |
| Keychain + API key onboarding | a key is required before the first recording | the first-run cliff |

A local model has no 30-minute cap, no rate limit and no per-token price. So the
right move is not "swap the transcriber" — it is to **delete the constraint and
the five workarounds with it**. The speaker-fragmentation bug in `STATUS.md`
does not get fixed; it stops being possible.

## The architectural lesson from Humla

Humla splits two things we currently do in one call, and that split is the whole
trick:

```
        ┌── transcription ──┐          ┌── diarization ──┐
audio → │ VAD-bounded 1–15s │   and    │  ONE pass over  │ → align by word time
        │ chunks, streamed  │          │  the whole file │
        └───────────────────┘          └─────────────────┘
```

Transcription is chunked because chunking makes it *live* — text appears while
you are still in the meeting. Diarization is **never** chunked, because a
speaker's identity is only stable if every second of the meeting is clustered
together. Word-level timestamps from the transcriber are what let the two be
rejoined exactly.

Humla's `audio-capture` sidecar rotates a chunk at a VAD pause once the chunk is
≥ 1 s, forced at 15 s (`main.swift:319`). Their diarizer then runs
`OfflineDiarizerManager` over the *entire* recording at stop time. That is why
they don't have our 8-speakers-for-3-people problem.

## The stack, measured rather than assumed

Everything below was run on this MacBook Pro today, not read off a doc page.

### Transcription — Apple `SpeechAnalyzer`

Built into macOS 26. No download, no key, no third-party dependency.

**Measured on the real 111-minute meeting**, through the actual
`AppleSpeechTranscriber` written for phase 1 rather than a toy probe:

```
17,299 words in 119.17s        -> 56x realtime
5.8s user CPU, 5% of one core  -> the work is on the ANE, not the CPU
last word ends at 111m 8s      -> nothing truncated
```

Against the Gemini transcript already stored for the same recording:

| | Gemini | On-device |
|---|---|---|
| characters | 92,105 | 89,915 (97.6%) |
| last word | 111m 8s | 111m 8s |
| wall clock | ~35 min, paced around rate limits | **119 s** |
| cost | ~$1.30 | **$0** |

Same end timestamp, so the coverage is genuinely equivalent rather than
truncated; the 2.4% character difference is punctuation and formatting, not
lost speech. Seventeen times faster in wall clock, free, and at 5% CPU it
leaves the machine alone.

Per-word timings arrive via the `.audioTimeRange` attribute, which is what the
diarization alignment in phase 2 needs.

**What phase 1 does not do:** the same run produced **27 turns, against
Gemini's 1473**. Apple's transcriber does not say who is speaking, so every
`Word` comes back with a nil speaker and turns can only be split on pauses. One
27-turn wall of text is not a usable transcript. That is the whole reason phase
2 exists, and it is why the engine is not yet selected anywhere in the app.

### The memory budget comes first

Jose runs Claude Code and two Docker Supabase stacks *during* meetings. Measured
on the machine mid-session:

```
free         0.07 GB
wired        2.63 GB
active       3.30 GB
inactive     3.13 GB
compressor   7.22 GB   (holding 24.94 GB of data, 3.5:1)
swap         5.41 GB used of 6.14 GB
swapouts     3,056,403
```

There is **no headroom**. The compressor alone owns 7.2 of 16 GB and the machine
has swapped out three million pages. Any plan that assumes "16 GB, a 2.3 GB
model is fine" is wrong here.

So the stack is chosen by **when** each piece runs, not by what scores best:

| Phase | Constraint | Consequence |
|---|---|---|
| During the meeting | must be featherweight — a stall here drops audio | nothing heavyweight in-process |
| After it stops | can be heavier, but the machine is still full | prefer out-of-process and unloadable |

**This is a strong argument for Apple's `SpeechAnalyzer`** and against bundling
whisper.cpp. Apple's transcriber runs in a system daemon on the ANE, so its
memory does not land in our process at all. Humla's local Whisper large-v3-q5
would sit at ~600 MB–1.1 GB resident *inside the app* for the whole meeting.
On this machine that is the difference between working and glitching.

FluidAudio's diarizer is ~30 MB of CoreML on the ANE and runs after stop, so it
is not a concern either.

### Summaries — a memory decision, not a quality one

My earlier reasoning was that Apple's 4,096-token window disqualifies it. The
window is real and fixed, and your meeting is 6.9× it:

```
1473 turns | 92,209 chars | 111.1 minutes
with speaker labels: ~112,800 chars ≈ 28,200 tokens
```

But "load a 4-bit 4B model in-process instead" is worse on *this* machine, and I
had the priorities the wrong way round. Ranked by what actually matters here:

| Option | App memory | Whole meeting at once? | Verdict |
|---|---|---|---|
| Apple `FoundationModels` | **~0** — system process, OS-shared | no, 4k window | **default** |
| Ollama / LM Studio endpoint | 0 in-app; ~2.3 GB out-of-process, unloadable | yes | quality tier |
| MLX Swift, in-process | 2.3–5 GB **held inside our app** | yes | not on this machine |

In-process MLX is the worst of the three here: the weights sit in our address
space for as long as the app is open, on a machine that is already swapping.
Dropped as the default.

**And the 4k window is more workable than I implied**, if the map step extracts
structure rather than prose:

1. **Extract**, over ~3k-token windows with a fresh session each: decisions,
   action items with owners, open questions — as `@Generable` structs. These are
   *local* facts. A small model is fine at spotting "Wilma will handle the
   alignment" in the passage where it was said; it does not need the arc.
2. **Reduce** once. The extracted facts from a 111-minute meeting come to
   roughly 1,500 tokens, which fits one 4k call with room for the narrative.

Prose-summarising each tenth of a meeting and stitching the prose is what loses
the arc. Extracting facts and writing the narrative once does not.

Ollama stays as the quality tier precisely because it is *out of process*: it
can be started for one summary and unloaded with `keep_alive: 0`, and if it dies
it takes nothing with it.

### Free 1.9 GB today

Now that the hosted project exists, the local `machina-scribe` Supabase stack is
redundant — 12 containers, **1,911 MB**. The second stack
(`builderpoint-staging`) is another ~400 MB, and the Docker VM itself is 1.7 GB
RSS on the host.

Stopping the machina-scribe stack is the largest single win available, and it is
a direct consequence of today's migration. **First move the real 111-minute
meeting out of that Docker volume** — it exists nowhere else, and the hosted
database is empty.

## What this deletes

| File | Fate |
|---|---|
| `Services/GeminiTranscriber.swift` | becomes one optional provider behind a protocol |
| `Audio/AudioChunker.swift` | gone — nothing caps us at 30 minutes any more |
| `ScribeCore/Stitching.swift` | gone — one diarization pass has no seams |
| `Services/ChunkCache.swift` | gone — nothing to resume when nothing can rate-limit |
| pacing / backoff in `RecordingSession` | gone |

`RecordingSession.transcribe` drops from ~70 lines of retry choreography to a
straight line: transcribe, diarize, align, save.

## Phasing

**1 — Local transcription behind a protocol.** Introduce `Transcriber` with
`AppleSpeechTranscriber` and the existing `GeminiTranscriber` as conformers.
Ship with Apple as default. Nothing else changes yet, so this is testable on its
own.

**2 — One-pass diarization + word alignment.** Link FluidAudio, run
`OfflineDiarizerManager` over the whole recording at stop, and assign each word
to the segment its midpoint falls in. Delete `AudioChunker`, `Stitching` and
`ChunkCache` in the same change — they are dead the moment this lands. Live tags
map onto the resulting speakers exactly as they do today.

**3 — Live transcript while recording.** Replace the Speech-framework "rough
preview" with the real transcriber over VAD-bounded chunks, so what you see
during the meeting is what gets saved. This is what makes it feel like Humla.

**4 — Local summaries.** `Summarizer` becomes a protocol; add the
FoundationModels implementation with map-reduce, and an OpenAI-compatible
client for Ollama/LM Studio.

**5 — System audio on the Mac.** `ScreenCaptureKit` as a second stream, kept
separate from the mic so "you said" and "they said" never mix. This is the
feature that makes remote calls work and is where Humla's two-stream design
pays off most.

## UI, taking Humla seriously

Humla's interface is worth copying because of *what it commits to*, not its
particular gold. Three things carry it:

**Inset cards on a canvas.** The sidebar is a rounded card floating on the
canvas with a gap around it, not a flush pane (`Layout.tsx`). It is the single
cheapest move that stops a Mac app looking like a settings window, and
`NavigationSplitView` fights it — we would build the shell by hand.

**One typeface, one accent, tokens for everything.** Every value lives in a
theme file implementing a documented token contract; components read tokens and
never colours. In SwiftUI that is an `EnvironmentKey` carrying a `Theme` struct.
Worth doing on day one — retrofitting it is what `design/REFACTOR.md` is.

**Speaker dots in a gutter, click to rename.** A 10 px dot in a left gutter with
a 32 px hit area, colour-cycled in first-encounter order so each meeting has a
stable mapping, and renaming one renames it everywhere. We already have the
rename-everywhere behaviour; we present it as a table.

Their domain vocabulary is also better than ours and is worth stealing wholesale
(`CONTEXT.md`): a **Note** is the unit (typed notes + transcript + summary
together), a **Session** is one recording within it, and the **Timeline** — turns
with per-word times — is *canonical*, with the transcript a projection of it.
Our `Meeting` / `TranscriptLine` split has no equivalent of Session, which is
why "record again into the same meeting" is not expressible for us today.

## Open questions

- **Apple Intelligence** needs turning on in System Settings before the free
  summary path can be tested at all. Nothing else in the plan depends on it.
- **Bumping to macOS 26 / iOS 26** drops older hardware. Decided: worth it —
  the OS models are the entire reason this can be free *and* seamless.
- **Everything above was measured on short synthetic audio.** The real
  111-minute recording is the test that matters, and re-running it is the first
  thing to do — it also settles the two fixes in `STATUS.md` that still have no
  real-world evidence behind them.
- **Pinning the speaker count to the roster** is the one design decision here
  that is ours rather than Humla's. It deserves a test with someone who joins
  late and is not on the list.
