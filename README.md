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

### The live preview

While recording, the screen shows a rough running transcript so you can see the
microphone is working. It is **on-device only** (`requiresOnDeviceRecognition`),
has no speaker labels, and is never saved — Gemini's diarized pass is the real
transcript. If a device cannot do on-device recognition for your language the
preview switches itself off rather than streaming the meeting to Apple.

iOS shows its own stock warning that speech data "will be sent to Apple" on the
permission prompt. That is boilerplate for the permission and does not reflect
what this app does; the usage string underneath says so.

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
packages/core/         Store + tool definitions, shared by both MCP servers
packages/stdio/        local MCP server over stdio (Claude Code, Claude Desktop)
packages/remote/       OAuth-protected MCP server on Cloudflare Workers
apps/ScribeCore/       pure logic: response parsing, turn building, stitching
apps/Scribe/           SwiftUI app, shared by the iOS and macOS targets
scripts/test-db.sh     runs the SQL tests against a throwaway Postgres
```

Both MCP servers register the *same* tool list from `packages/core`, so they
cannot drift apart.

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

Two ways in. They serve identical tools; pick either or run both.

**Local (stdio).** Simplest, nothing to deploy. Works in Claude Code and Claude
Desktop on the machine it runs on.

```bash
npm install && npm run build
```

Copy `.env.example` to `.env`, fill in the three values, then:

```bash
claude mcp add machina-scribe --env SUPABASE_URL=... --env SUPABASE_SERVICE_ROLE_KEY=... --env SCRIBE_USER_ID=... -- node /absolute/path/to/packages/stdio/dist/index.js
```

**Remote (Cloudflare Workers).** Reachable from claude.ai and the mobile apps,
protected by OAuth. Sign-in is checked against your own Supabase project, so
there is no second set of credentials.

```bash
cd packages/remote
npx wrangler kv namespace create OAUTH_KV     # put the id in wrangler.jsonc
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
# set SUPABASE_URL and SUPABASE_ANON_KEY under "vars" in wrangler.jsonc
npx wrangler deploy
```

Then add `https://<your-worker>.workers.dev/mcp` as a custom connector in
Claude. It registers itself (dynamic client registration), sends you to a login
page, and you sign in with the same account the app uses.

How the authorization works, and why it is safe to hand a service-role key to a
Worker:

- The Worker never trusts a user id from the caller. It comes from the OAuth
  grant, is encrypted into the token, and is the only thing that scopes queries.
- The login form posts the authorization request back through the browser, so
  the redirect URI is re-checked against what the client registered before any
  code is issued — a tampered field cannot turn it into an open redirect.
- PKCE (S256) is required, and `/mcp` rejects unauthenticated requests.

`packages/remote/test/oauth-flow.test.mjs` asserts all of the above against a
running `wrangler dev`.

### Tools

| Tool | What it does |
|---|---|
| `list_meetings` | recent meetings with length and who spoke |
| `get_transcript` | full speaker-attributed transcript |
| `search_transcripts` | full-text search, optionally scoped to one person |
| `list_people` | everyone named across all meetings |
| `name_speaker` | fix attribution; relabels the whole meeting |
| `set_meeting_summary` | save a summary back onto a meeting |

So you can ask Claude *"what did Priya commit to in the roadmap sync?"* or
*"search every meeting for what we decided about latency."*

---

## Tests

```bash
./scripts/test-db.sh                # SQL logic, throwaway Postgres (needs Docker)
cd apps/ScribeCore && swift test    # parsing + cross-chunk stitching
npm run typecheck --workspaces      # both MCP servers
```

The remote server's OAuth flow is tested separately, against a running dev
server — see `packages/remote/test/README.md`.

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
