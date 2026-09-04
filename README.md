# machina-scribe

In-person meeting notes that know who said what. Record on iPhone or Mac, tap a
name once while someone is talking, and every turn in that voice carries their
name. Transcripts are kept; **audio never is**.

Claude reads the transcripts through an MCP server.

---

## How speaker tagging actually works

This is the part worth understanding, because it drives everything else.

Gemini has two transcription endpoints, and only one of them can tell speakers
apart:

| | `gemini-3.5-transcribe-live` | `gemini-3.5-transcribe` |
|---|---|---|
| Streaming | yes | no, whole file |
| **Speaker diarization** | **no** | **yes, up to 8 voices** |
| Max length | 10 min/session | 30 min/request with diarization |

Live streaming cannot say who spoke, so tagging cannot work off a live
transcript. Instead:

1. **During the meeting**, tapping a name records a *timestamp anchor* —
   "Jose, at 4:12". It does not cut the transcript anywhere.
2. **On stop**, the recording goes to the unary model, which returns turns
   labelled `spk_1`, `spk_2`… consistent across the whole recording.
3. **The anchor lands inside one of those turns**, which identifies that voice.
   Naming the voice names every turn it takes — before *and* after your tap.

One tap per person, for the whole meeting. You can also skip tagging entirely
and name the voices from the transcript afterwards; same mechanism.

Because segments reference a `speakers` row rather than storing a name, renaming
is a single write that relabels the entire meeting. A manual rename always wins
over a tag-inferred one and survives re-running the matcher.

### Meetings longer than 30 minutes

The recording is split into 20-minute pieces that overlap by 40 seconds. Each
piece is diarized independently, so `spk_1` in piece two may be a different
person than in piece one. `Stitcher` repairs the seam by matching the text of
the overlapping turns — the same audio transcribed twice — and remapping labels.

When a seam cannot be matched confidently it creates a *new* speaker rather than
guessing. The failure mode is one extra name to assign, never words attributed
to the wrong person.

---

## Layout

```
supabase/migrations/   schema, RLS, and the tag-resolution logic (SQL)
supabase/local-tests/  SQL tests for that logic
mcp-server/            MCP server that exposes transcripts to Claude (TypeScript)
apps/ScribeCore/       pure logic: response parsing, turn building, stitching
apps/Scribe/           SwiftUI app, shared by the iOS and macOS targets
scripts/test-db.sh     runs the SQL tests against a throwaway Postgres
```

---

## Setup

### 1. Database

Point the CLI at your project and push the schema:

```bash
supabase link --project-ref YOUR-PROJECT-REF && supabase db push
```

Then create your account — either through the app's sign-up, or in the Supabase
dashboard under Authentication → Users.

### 2. Gemini key

Get one at <https://aistudio.google.com/apikey>. You paste it into the app's
Settings screen; it is stored in the keychain and sent only to Google. Roughly
**$0.009/minute** of audio.

### 3. Apps

```bash
cd apps && xcodegen generate && open Scribe.xcodeproj
```

Two targets: `Scribe-iOS` and `Scribe-macOS`, sharing all sources. On first
launch enter your Supabase URL and anon key (both publishable) and sign in.

### 4. MCP server

```bash
cd mcp-server && npm install && npm run build
```

Copy `.env.example` to `.env` and fill in the three values, then register it:

```bash
claude mcp add machina-scribe --env SUPABASE_URL=... --env SUPABASE_SERVICE_ROLE_KEY=... --env SCRIBE_USER_ID=... -- node /absolute/path/to/mcp-server/dist/index.js
```

Tools it exposes:

| Tool | What it does |
|---|---|
| `list_meetings` | recent meetings with length and who spoke |
| `get_transcript` | full speaker-attributed transcript |
| `search_transcripts` | full-text search, optionally scoped to one person |
| `list_people` | everyone named across all meetings |
| `name_speaker` | fix attribution; relabels the whole meeting |
| `set_meeting_summary` | save a summary back onto a meeting |

So you can ask Claude things like *"what did Priya commit to in the roadmap
sync?"* or *"search every meeting for what we decided about latency."*

---

## Tests

```bash
./scripts/test-db.sh                     # SQL logic, throwaway Postgres (needs Docker)
cd apps/ScribeCore && swift test         # parsing + cross-chunk stitching
cd mcp-server && npm run typecheck
```

---

## On privacy

Audio is written to the OS temporary directory, uploaded to Gemini, and deleted
as soon as the transcript is stored. It is not uploaded to Supabase and not kept
on the device. A failed transcription keeps the file so you can retry; discarding
the meeting removes it.

The Supabase anon key is publishable and lives in user defaults. The Gemini key
lives in the keychain. The service-role key is only ever used by the MCP server
on your own machine — it bypasses row level security, so it must not go into a
client app.
