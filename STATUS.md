# Where this stands — 2026-09-04

Working notes for picking the project back up. `README.md` explains how the
thing works; this file is what is true right now and what to do next.

## Working end to end

Recorded a real 111-minute meeting on the Mac and got a speaker-attributed
transcript, a summary, Linear issues and a Notion page out of it. The whole
chain has been exercised on real audio, not fixtures.

| Piece | State |
|---|---|
| Mac app | `/Applications/Scribe.app`, signed with the real team, 📝 icon |
| iPhone app | installed and signed; installs over Wi-Fi, no cable |
| Gemini transcription | verified live, diarization confirmed |
| Summaries | `gemini-3.1-flash-lite`, ~$0.006/meeting |
| Notion export | database created, full transcript verified end to end |
| MCP (stdio + remote OAuth) | built and tested; remote not deployed |
| Supabase | **hosted** — `lclnwhbhoibnipcbgbpi`, us-west-2 |

## Hosted Supabase — done

Created 2026-09-04 once Supabase's Management API recovered.

- Project **`machina-scribe`**, ref `lclnwhbhoibnipcbgbpi`
- Org **Machina Labs** (`wvghonxfpprrwrtczcwe`), region **us-west-2** (Oregon)
- Repo is linked; all four migrations applied; `supabase db diff --linked`
  reports no drift
- Password still in `.secrets/db-password`

Data migrated 2026-09-04 and the local stack stopped. All 1473 segments,
2 meetings, 9 speakers, 4 people, 6 attendees, 4 live tags and the single auth
user -- same UUID, so every `user_id` FK still resolves and the same password
still signs in. Verified by matching row counts **and** an MD5 over the
concatenated transcript text on both sides; RLS checked by impersonating the
user (2 meetings, 1473 transcript lines visible).

Two fallbacks kept: `backups/local-snapshot-2026-09-04.sql` (gitignored, in the
main checkout) and the Docker volumes, which `supabase stop` preserved rather
than deleted.

Remaining: repoint both apps in Settings from `http://<mac-lan-ip>:54421` to the
hosted URL, then drop `NSAllowsLocalNetworking` from both Info.plist blocks in
`apps/project.yml`.

`supabase start` brings the local stack back for offline work. Only the
machina-scribe stack was stopped -- the builderpoint and drivetrack ones are
untouched.

## Public repo

`https://github.com/DriveTrack/machina-scribe` — public, `main` pushed. History
was scanned for credentials before publishing; nothing found.

## Going local

See `docs/LOCAL-FIRST-PLAN.md`. Short version: Apple's `SpeechAnalyzer` and
FluidAudio's offline diarizer both measured working on this Mac, which removes
Gemini's 30-minute cap and with it the chunking, stitching, caching and pacing
that cap forced on us. `FoundationModels` needs Apple Intelligence turned on
before the free summary path can be tested at all.

## Costs, measured rather than guessed

- Transcription: ~**$2** for the 111-minute meeting, but that included a
  failed run redoing three completed parts. A clean run is ~**$1.30**.
- Summary: ~**$0.006**. Flash-Lite matched 3.5-Flash on the same transcript —
  same decision, same action item, same owner and deadline — at a sixth of
  the price, which is why it is the default.
- Audio is 32 tokens/second, verified against a known-length clip.

## Bugs found by running it, worth not reintroducing

Each of these looked like something else first:

- **PostgREST caps reads at 1000 rows** and says nothing. A 1471-turn
  transcript appeared to end at 1:20:35 and looked complete. Both the app and
  the MCP server page now — the MCP one would have quietly handed Claude two
  thirds of a meeting to summarise.
- **Editing `Info.plist` after signing** invalidates the signature, and a
  sandboxed app whose signature fails is killed before its own code runs. It
  presented as an unexplained crash on launch.
- **Callbacks inheriting `@MainActor`** that fire on the TCC and realtime
  audio threads trap under Swift 6. Two separate crashes.
- **Speaker labels are `spk:0` live**, not the `spk_1` the docs show. Speakers
  are numbered by who talks first, so the spelling stops mattering.
- **LaunchServices caches an app icon per bundle** — a correct icon can be
  invisible until the bundle is re-registered and the Dock restarted.
- Audio used to live only in the OS temp directory until a transcript
  succeeded, so a long failed transcription could lose a meeting outright.

## Known rough edges

- **Long meetings fragment speakers.** 111 minutes with 3 tagged people came
  back as 8 speakers: anyone silent across a chunk boundary is re-identified.
  Overlap went 40s → 2min and chunks 20 → 27min, and the transcript offers a
  one-tap merge — but this has **not been retested on a fresh long meeting**.
- **Rate limits.** Six ~38k-token requests in a row exhaust tokens-per-minute
  even on the paid tier. There is now 45s pacing between parts, backoff using
  the API's own `retryDelay`, and a per-chunk cache so a retry resumes. Also
  untested on a fresh long meeting.
- **Remote MCP is built but not deployed.** Needs a Cloudflare KV namespace
  and `wrangler deploy`; the local stdio server works today.
- The MCP server failed to connect at the start of this session
  (`-32603 Internal server error`) — likely the env vars point at a local
  Supabase that was down. Worth re-checking once hosted.

## Next, roughly in order

1. Create the hosted Supabase project the moment their API recovers, migrate,
   repoint both apps.
2. Record a fresh long meeting and confirm pacing + the wider overlap actually
   hold up. Those are the two fixes with no real-world evidence behind them.
3. Deploy the remote MCP Worker if phone access to transcripts matters.
4. Consider rotating the Gemini key — it appeared in a session transcript.

## Things that are easy to get wrong

- `./scripts/install-mac.sh` and `./scripts/install-iphone.sh` do the whole
  build-and-install. Do not hand-edit anything inside a signed bundle.
- `apps/Local.xcconfig` holds the Apple team id and is gitignored.
- Secrets live in `.secrets/` and `.env`, both gitignored. The apps read their
  keys from the **keychain**, not those files — those are only for scripts.
- Run `xcodegen generate` in `apps/` after adding a source file.
