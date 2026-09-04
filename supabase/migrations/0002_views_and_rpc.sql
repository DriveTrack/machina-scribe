-- Read models and the operations both the apps and the MCP server share.
--
-- On authentication: the Swift apps sign in as the user, so auth.uid() is set
-- and RLS does the scoping. The MCP server connects with the service role,
-- where auth.uid() is null and RLS is bypassed -- so these functions take an
-- explicit p_user_id for that path. This grants the service role nothing it
-- did not already have; it is how a keyholder names *which* user it is acting
-- for, not a way around a check.

-- ---------------------------------------------------------------------------
-- transcript_lines: the shape everything actually wants to read. Speaker name
-- falls back to the raw diarization label while a voice is still unnamed.
-- ---------------------------------------------------------------------------
create view public.transcript_lines
with (security_invoker = on)
as
select
  s.user_id,
  s.meeting_id,
  s.idx,
  s.start_ms,
  s.end_ms,
  s.text,
  sp.id                      as speaker_id,
  sp.label                   as speaker_label,
  coalesce(p.name, sp.label) as speaker,
  sp.resolved_by,
  p.id                       as person_id
from public.segments s
left join public.speakers sp on sp.id = s.speaker_id
left join public.people   p  on p.id  = sp.person_id;

-- ---------------------------------------------------------------------------
-- effective_user: auth.uid() when a real session exists, else the caller's
-- explicit claim. Raises rather than silently acting on nobody's data.
-- ---------------------------------------------------------------------------
create or replace function public.effective_user(p_user_id uuid default null)
returns uuid
language plpgsql
stable
as $$
declare
  v_user uuid := coalesce(auth.uid(), p_user_id);
begin
  if v_user is null then
    raise exception 'not authenticated: no session and no user id supplied';
  end if;
  return v_user;
end;
$$;

-- ---------------------------------------------------------------------------
-- name_speaker: attach a human name to one diarized voice. Because segments
-- point at the speaker row rather than carrying a name, this renames every
-- turn in the meeting -- past and future -- in a single write.
-- ---------------------------------------------------------------------------
create or replace function public.name_speaker(
  p_meeting_id uuid,
  p_label      text,
  p_name       text,
  p_user_id    uuid default null
)
returns uuid
language plpgsql
as $$
declare
  v_user   uuid := public.effective_user(p_user_id);
  v_person uuid;
  v_id     uuid;
begin
  insert into public.people (user_id, name)
  values (v_user, btrim(p_name))
  on conflict (user_id, lower(name)) do update set name = excluded.name
  returning id into v_person;

  update public.speakers
     set person_id      = v_person,
         resolved_by    = 'manual',
         match_delta_ms = null
   where meeting_id = p_meeting_id
     and label      = p_label
     and user_id    = v_user
  returning id into v_id;

  if v_id is null then
    raise exception 'no speaker % in meeting %', p_label, p_meeting_id;
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_live_tags: turn the taps made during the meeting into named
-- speakers. A tap lands inside the turn of whoever was talking, so the segment
-- containing it identifies the voice -- and naming that voice names every turn
-- it ever speaks. One tap, whole meeting.
--
-- Manual names always win; this never overwrites a human correction.
-- ---------------------------------------------------------------------------
create or replace function public.resolve_live_tags(
  p_meeting_id uuid,
  -- how far from a tap we will still look for a turn, when the tap fell in a
  -- gap (silence, crosstalk) rather than inside one
  p_window_ms  integer default 5000,
  p_user_id    uuid default null
)
returns integer
language plpgsql
as $$
declare
  v_user    uuid := public.effective_user(p_user_id);
  v_updated integer := 0;
begin
  with tag_hits as (
    -- pair every tap with the turn it most plausibly belongs to
    select distinct on (t.id)
      t.id         as tag_id,
      t.name       as name,
      s.speaker_id as speaker_id,
      case
        when t.at_ms between s.start_ms and s.end_ms then 0
        -- Tap landed after a turn ended: you reached for the button as they
        -- were finishing. Very likely still that speaker.
        when t.at_ms > s.end_ms then t.at_ms - s.end_ms
        -- Tap landed before a turn began: possible, but reaction lag makes
        -- "the person who just stopped" the better bet than "the person about
        -- to start", so an equal gap backwards beats an equal gap forwards.
        else (s.start_ms - t.at_ms) * 3
      end          as delta
    from public.live_tags t
    join public.segments s
      on s.meeting_id = t.meeting_id
     and s.speaker_id is not null
     and s.end_ms   >= t.at_ms - p_window_ms
     and s.start_ms <= t.at_ms + p_window_ms
    where t.meeting_id = p_meeting_id
      and t.user_id    = v_user
    order by t.id, delta asc, s.idx asc
  ),
  best_per_speaker as (
    -- one meeting can carry several taps for the same voice; trust the tap
    -- that landed most squarely inside a turn
    select distinct on (speaker_id)
      speaker_id, name, delta, tag_id
    from tag_hits
    order by speaker_id, delta asc
  ),
  named as (
    insert into public.people (user_id, name)
    select v_user, btrim(name) from best_per_speaker
    on conflict (user_id, lower(name)) do update set name = excluded.name
    returning id, lower(name) as lname
  ),
  applied as (
    update public.speakers sp
       set person_id      = n.id,
           resolved_by    = 'live_tag',
           match_delta_ms = b.delta
      from best_per_speaker b
      join named n on n.lname = lower(btrim(b.name))
     where sp.id = b.speaker_id
       and sp.resolved_by <> 'manual'
    returning sp.id
  ),
  backlink as (
    update public.live_tags t
       set resolved_speaker_id = b.speaker_id
      from best_per_speaker b
     where t.id = b.tag_id
    returning t.id
  )
  select count(*) into v_updated from applied;

  return v_updated;
end;
$$;

-- ---------------------------------------------------------------------------
-- search_transcripts: full-text across every turn, best match first.
-- ---------------------------------------------------------------------------
create or replace function public.search_transcripts(
  p_query   text,
  p_person  text default null,
  p_limit   integer default 50,
  p_user_id uuid default null
)
returns table (
  meeting_id    uuid,
  meeting_title text,
  started_at    timestamptz,
  idx           integer,
  start_ms      integer,
  speaker       text,
  text          text,
  rank          real
)
language plpgsql
stable
as $$
declare
  v_user uuid := public.effective_user(p_user_id);
begin
  return query
  select
    m.id,
    m.title,
    m.started_at,
    s.idx,
    s.start_ms,
    coalesce(p.name, sp.label) as speaker,
    s.text,
    ts_rank(s.tsv, websearch_to_tsquery('english', p_query)) as rank
  from public.segments s
  join public.meetings m on m.id = s.meeting_id
  left join public.speakers sp on sp.id = s.speaker_id
  left join public.people   p  on p.id  = sp.person_id
  where s.user_id = v_user
    and s.tsv @@ websearch_to_tsquery('english', p_query)
    and (p_person is null or lower(coalesce(p.name, sp.label)) = lower(btrim(p_person)))
  order by rank desc, m.started_at desc, s.idx
  limit greatest(1, least(p_limit, 500));
end;
$$;
