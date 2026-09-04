-- machina-scribe: speaker-attributed meeting transcripts.
-- Audio is never stored; only text, timings and speaker attribution.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- people: identities that persist across meetings, so "Jose" is the same Jose
-- in every transcript and Claude can answer "what did Jose say about X".
-- ---------------------------------------------------------------------------
create table public.people (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null check (length(btrim(name)) > 0),
  -- optional freeform context ("VP Eng, joined Q3") surfaced to Claude via MCP
  note       text,
  created_at timestamptz not null default now()
);

-- case-insensitive uniqueness per user; an expression index rather than a
-- UNIQUE constraint, which cannot take expressions. ON CONFLICT infers it.
create unique index people_user_name_idx on public.people (user_id, lower(name));

-- ---------------------------------------------------------------------------
-- meetings
-- ---------------------------------------------------------------------------
create type public.meeting_status as enum (
  'recording',      -- capture in progress on a device
  'transcribing',   -- audio handed to Gemini, awaiting diarized text
  'ready',
  'failed'
);

create table public.meetings (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  title        text,
  -- where it happened, typed by hand or left null
  location     text,
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  duration_ms  integer check (duration_ms is null or duration_ms >= 0),
  source       text check (source in ('ios', 'macos')),
  status       public.meeting_status not null default 'recording',
  -- populated when status = 'failed'
  error        text,
  language     text,
  -- notes the user types during or after the meeting, kept apart from speech
  notes        text,
  summary      text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index meetings_user_started_idx on public.meetings (user_id, started_at desc);
create index meetings_status_idx on public.meetings (user_id, status);

-- ---------------------------------------------------------------------------
-- speakers: one row per diarized voice per meeting. Gemini gives us an opaque
-- label ("Speaker 1"); person_id is how that voice got a name.
-- ---------------------------------------------------------------------------
create type public.speaker_resolution as enum (
  'unresolved',  -- diarized but nobody has said who it is
  'live_tag',    -- a tap during the meeting landed inside this speaker's audio
  'manual'       -- named from the transcript afterwards
);

create table public.speakers (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  meeting_id  uuid not null references public.meetings(id) on delete cascade,
  label       text not null,
  person_id   uuid references public.people(id) on delete set null,
  resolved_by public.speaker_resolution not null default 'unresolved',
  -- how confident the live-tag match was (ms from tag to segment); null if manual
  match_delta_ms integer,
  created_at  timestamptz not null default now(),
  unique (meeting_id, label)
);

create index speakers_meeting_idx on public.speakers (meeting_id);
create index speakers_person_idx on public.speakers (person_id);

-- ---------------------------------------------------------------------------
-- segments: the transcript itself, one row per diarized turn.
-- ---------------------------------------------------------------------------
create table public.segments (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  meeting_id uuid not null references public.meetings(id) on delete cascade,
  speaker_id uuid references public.speakers(id) on delete set null,
  idx        integer not null,
  start_ms   integer not null check (start_ms >= 0),
  end_ms     integer not null check (end_ms >= start_ms),
  text       text not null,
  -- which ~20min transcription chunk this came from; used to audit seam stitching
  chunk      smallint not null default 0,
  tsv        tsvector generated always as (to_tsvector('english', text)) stored,
  unique (meeting_id, idx)
);

create index segments_meeting_idx on public.segments (meeting_id, idx);
create index segments_speaker_idx on public.segments (speaker_id);
create index segments_tsv_idx on public.segments using gin (tsv);

-- ---------------------------------------------------------------------------
-- live_tags: "that's Jose talking, right now" taps recorded during capture.
-- Kept after resolution so a bad auto-match can be re-run or audited.
-- ---------------------------------------------------------------------------
create table public.live_tags (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  meeting_id uuid not null references public.meetings(id) on delete cascade,
  person_id  uuid references public.people(id) on delete set null,
  -- denormalized so a tag survives the person being renamed or deleted
  name       text not null,
  at_ms      integer not null check (at_ms >= 0),
  -- set once the tag has been matched against a diarized speaker
  resolved_speaker_id uuid references public.speakers(id) on delete set null,
  created_at timestamptz not null default now()
);

create index live_tags_meeting_idx on public.live_tags (meeting_id, at_ms);

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger meetings_touch_updated_at
  before update on public.meetings
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row level security: every table is scoped to the owning user.
-- ---------------------------------------------------------------------------
alter table public.people    enable row level security;
alter table public.meetings  enable row level security;
alter table public.speakers  enable row level security;
alter table public.segments  enable row level security;
alter table public.live_tags enable row level security;

create policy people_owner    on public.people    for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy meetings_owner  on public.meetings  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy speakers_owner  on public.speakers  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy segments_owner  on public.segments  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy live_tags_owner on public.live_tags for all using (user_id = auth.uid()) with check (user_id = auth.uid());
