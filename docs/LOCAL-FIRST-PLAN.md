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

### Speaker separation — FluidAudio `OfflineDiarizerManager`

Apache 2.0 Swift package, CoreML on the Neural Engine: pyannote community-1
segmentation, WeSpeaker embeddings, VBx clustering with PLDA. ~30 MB fetched
once. Linked directly -- Humla shells out to a Swift sidecar only because their
app is Rust, and we are already Swift.

**Measured on the real 111-minute meeting, through the shipped code.** Four
people were in it: Jose, Chris, Nia, Shania.

| | Gemini (chunked) | Local, no roster | Local, pinned to 4 |
|---|---|---|---|
| speakers | **8** | 3 | **4** |
| turns | 1471 | 596 | 659 |
| wall clock | ~35 min | ~165 s | ~169 s |
| cost | ~$1.30 | $0 | $0 |

Gemini's eight speakers for four people is the bug in `STATUS.md`, and it is
worse than the count alone suggests: **Jose came back as Speakers 1, 5 *and*
7**, Shania as 4 and 6. Every seam between 27-minute chunks was a chance to
re-identify whoever had been quiet across it. One pass over the whole recording
has no seams.

**Both error directions are real and they are opposite.** Chunked Gemini
over-counts; whole-file clustering *under*-counts -- run without a roster the
same audio came back as three, merging Nia and Shania.

**But pinning to the roster was the wrong fix, and running it end to end proved
it.** The stored roster for that meeting named three people; four spoke, because
Shania was never on the list. A sweep over every option, against a truth of
four:

```
unpinned                  3 speakers   under by 1
exactly roster (3)        3 speakers   under by 1
min roster, no max        3 speakers   under by 1
min roster, max roster+2  3 speakers   under by 1
min roster, max roster+4  3 speakers   under by 1
exactly truth (4)         4 speakers   correct
```

Two things fall out. `min` and `max` do not move the answer at all -- only
`exactly` does. And `exactly <roster>` is right only when the roster is right:
name four attendees, have one stay silent, and it *forces* the clusterer to
split somebody in two. That is the over-counting bug we came here to escape,
reintroduced from the other side.

So the count is never guessed. The retry runs on **evidence**: every live tag is
an observation that a particular person was speaking, and unlike a guest list a
tap cannot over-state -- somebody had to be talking for it to be made. If more
distinct people were tapped than voices were found, the clusterer merged two of
them, and only then is a second pass run pinned to the number observed. A retry
that comes back no better is discarded, because the audio has said it does not
support the split.

### Joining the two passes

Transcription gives words with timings and no speaker; diarization gives
speaker stretches and no words. `Diarization.assign` joins them on time:

- **By word midpoint, not start.** A word straddling a boundary belongs to
  whoever spoke most of it; using the start hands the first word of every turn
  to the previous speaker.
- **Words in a gap take the nearest segment.** Diarizers leave gaps -- one turn
  in sixteen fell in one during testing. Leaving those unattributed splits a
  turn at that point and reads as a phantom speaker change.
- **The shortest covering segment wins.** Segments overlap, and a brief one
  nested in a long one is the diarizer being specific. A unit test caught this
  returning the container and discarding the interjection.
- **Single-word flickers are absorbed.** A lone word carrying a neighbour's
  voice mid-sentence with no pause either side is reassigned; a genuine
  backchannel has pauses around it and survives.

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

### Summaries — built, with one part untested

Three engines behind `MeetingSummarizing`, chosen in Settings. On-device is the
default; each degrades to the next rather than failing.

**On device (`FoundationModels`).** Free, offline, and it costs this app no
memory — the model lives in a system process. The catch is a hard 4,096-token
window shared by prompt, response and session history, against a 111-minute
meeting of roughly 28,000 tokens.

So it maps and reduces, but extracts *structure* rather than prose. Prose-
summarising each tenth of a meeting and gluing the paragraphs together is what
loses the thread, because no step ever sees the meeting. Decisions and
commitments are **local facts** — "Wilma will handle the alignment" is entirely
present in the passage where it was said. Those facts then collapse to about
1,500 tokens, which fits one call with room to write the overview once, over
all of them. A window that trips a guardrail or overruns is skipped rather than
failing the whole summary: meeting talk about people or money is exactly what
trips a safety filter, and a summary with a gap beats no summary.

**Local server.** Any OpenAI-compatible endpoint — Ollama, LM Studio,
llama.cpp. A 4B model at 4-bit holds the whole meeting in one pass, so no
map-reduce and nothing lost between windows. Out of process on purpose: those
weights would otherwise stay resident in this app for as long as it is open.
`isLocal` is false for a non-loopback host, so the UI cannot claim a meeting
stayed put when it did not.

**Gemini.** Unchanged, still selectable, and now honestly labelled as uploading
the transcript.

#### What running it actually taught us

The on-device summariser was written before Apple Intelligence was switched on,
so it shipped compiling but unexecuted. The first real run found three things no
amount of reading would have.

**A prompt's example is an answer the model will give you.** The reduce
instruction illustrated a good title with *"Q4 migration timing"*. The digest
was uncapped -- 80 topics, 38 commitments, 131 "open questions" -- which came to
~3,500 tokens against the 4,096 the model has for prompt, schema and answer
together. It overflowed, the model never saw the facts, and it answered from the
only thing left in front of it: a meeting about vehicle inventory came back
titled **"Q4 migration timing"**, with a summary invented to match. There is now
no worked example anywhere in these instructions, and the digest is ranked by
how many windows agreed on each item and capped, with a second, tighter cap if
the prompt is still too long.

**A model asked to leave a field empty will write the word "empty".** Action
items came back `due Not specified`, which renders in the UI as though a
deadline exists. Placeholders are now filtered out deterministically rather than
asked away, because asking does not reliably work.

**A model asked for a deadline "in the speaker's own words" will paste a
paragraph.** One `due` field held eighty words of somebody thinking aloud.
Anything over 60 characters is not a deadline and is dropped; the task survives.

Where it landed, on the same 111-minute meeting, entirely on this Mac and for
nothing:

```
TITLE:   Builder Point project updates
SUMMARY: The meeting discussed updates to the Builder Point project, including
         project deadlines, lead reassignment, and feature additions. The
         project is left in a state of progress with some decisions made and
         others pending. Open questions remain regarding Chris Rieplinger's
         role, mechanic hookups, and business retirement.

ACTION ITEMS (60), e.g.
  - Set project deadline to seven days from creation [Jose]
  - Allow approvers to click on approvals to see status [Jose]
  - Allow Chris Rieplinger to add line items to estimates [Jose]
```

**The narrative summary is the weak part, and tightening the prompt trades one
failure for another.** Across four runs on the same transcript the title was
right every time and the extracted lists were consistently useful, but the
two-sentence overview swung between enumerating the lists ("...decisions to
reassign leads, improve reports, promote to prod, finish projects, import
catalog items...") and saying nothing at all ("The meeting went well, with no
major issues"). The instruction now forbids both by name.

Decision counts across those runs were 19, 9 and 2 as the wording changed. A 3B
model reading one passage at a time cannot reliably separate a decision from a
strong opinion, and no prompt makes it deterministic. **This is the honest
ceiling of a 4096-token model, not a bug still to fix.**

What that means in practice: trust the **title** and the **structured lists** --
they come from the extraction pass, which is the part this model is good at.
Treat the overview as a nicety. For a meeting where the narrative matters, the
local-server tier sees the whole transcript at once and does not have to
reconstruct the meeting from fragments.

#### Where each engine stands

| | Status |
|---|---|
| Window splitting, ranking, capping, placeholder filtering, reply parsing | **50 unit tests** |
| On-device summariser | **run on the real 111-minute meeting**, four times |
| Local-server summariser | **run end to end** against a stand-in server |
| Gemini | unchanged |

Cost of an on-device summary of a 111-minute meeting: **~5 minutes at 2% CPU,
and nothing in money or memory.**

### Free 1.9 GB today

Now that the hosted project exists, the local `machina-scribe` Supabase stack is
redundant — 12 containers, **1,911 MB**. The second stack
(`builderpoint-staging`) is another ~400 MB, and the Docker VM itself is 1.7 GB
RSS on the host.

Stopping the machina-scribe stack is the largest single win available, and it is
a direct consequence of today's migration. **First move the real 111-minute
meeting out of that Docker volume** — it exists nowhere else, and the hosted
database is empty.

## Storage — one file on the device

Transcription and speaker separation both run here now, so storing the result
on somebody's server would have made "your meeting never leaves this machine"
untrue for the only artefact anyone actually reads.

Meetings live in `~/Library/Application Support/Scribe/scribe.sqlite`, through
the system SQLite every Apple platform already ships. No package, no account,
nothing to configure before the app works -- and the whole Supabase SDK comes
out of the binary with it.

The schema mirrors the Postgres one row for row, minus `user_id`: that column
scoped rows to an account, and there is exactly one user of a file in your own
home directory. Keeping the shape means an optional sync can map straight back
onto it later.

Two things the old backend forced on us are simply gone. There is no 1000-row
paging ceiling to silently truncate a transcript, and no rate limit to pace
around. Two things it gave us had to be rebuilt: `resolve_live_tags` and
`tag_problems` are now Swift, with the same "a tap lands inside the turn of
whoever was talking" rule and the same bias toward whoever *just stopped*
speaking over whoever is about to start.

### What real data caught

The existing 111-minute meeting was imported and then read back through
`LocalStore` itself rather than eyeballed, which found two things a test
against fixtures would not have:

- **Every `where meeting_id = ?` matched nothing.** Postgres writes UUIDs
  lowercase; Swift's `UUID.uuidString` is uppercase; SQLite compares text
  case-sensitively. Meetings listed fine (no filter) while every transcript
  came back empty. Fixed on both sides: ids bind lowercased, and the id columns
  are `collate nocase` so it cannot recur whatever writes them.
- **Search missed words it contained.** FTS5 matches whole tokens, so
  `transcript` found nothing in a meeting that says "transcripts" and
  "transcription". Now tokenised `porter unicode61`, and the query is parsed
  into quoted terms rather than passed through -- an apostrophe in a normal
  phrase is a syntax error in FTS5's query language, which would have failed
  the search rather than returning nothing.

Verified after the fix: 1473 segments imported, byte-for-byte identical to the
hosted rows, and read back through the app's own store as 1471 transcript lines
for the long meeting with speakers resolved to Chris, Jose, Nia and Shania.

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
