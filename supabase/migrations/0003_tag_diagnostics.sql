-- Live tags fail in two ways that used to happen silently, and real recordings
-- hit both immediately:
--
--   * Several people get tagged inside one diarized turn. Only one name can
--     win, and the rest were dropped without a word -- so a transcript came
--     back confidently attributing everything to whoever happened to win.
--
--   * A tag lands in a gap between turns that is wider than the search window
--     (long pause, crosstalk, someone talking over the mic). It matched
--     nothing and simply vanished.
--
-- Neither is fixable by better matching alone: sometimes diarization really did
-- merge two people, and no heuristic can undo that. What matters is that the
-- app can say so instead of quietly guessing.

-- Every distinct name whose tag pointed at this voice. More than one entry
-- means the tags disagreed, which usually means diarization merged speakers.
alter table public.speakers
  add column if not exists competing_names text[] not null default '{}';

create or replace function public.resolve_live_tags(
  p_meeting_id uuid,
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
  -- Start from a clean slate so re-running is idempotent rather than additive.
  update public.live_tags
     set resolved_speaker_id = null
   where meeting_id = p_meeting_id and user_id = v_user;

  with tag_hits as (
    -- pair every tap with the turn it most plausibly belongs to
    select distinct on (t.id)
      t.id         as tag_id,
      btrim(t.name) as name,
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
  votes as (
    -- How many taps each name got for each voice, and how close the best of
    -- them landed.
    select speaker_id, name, count(*) as tally, min(delta) as best_delta
    from tag_hits
    group by speaker_id, name
  ),
  winner as (
    -- Majority first, closeness only to break a tie. Nearest-wins alone let a
    -- single stray tap outrank several consistent ones.
    select distinct on (speaker_id)
      speaker_id, name, best_delta
    from votes
    order by speaker_id, tally desc, best_delta asc
  ),
  disagreements as (
    select speaker_id, array_agg(distinct name order by name) as names
    from votes
    group by speaker_id
  ),
  named as (
    insert into public.people (user_id, name)
    select v_user, name from winner
    on conflict (user_id, lower(name)) do update set name = excluded.name
    returning id, lower(name) as lname
  ),
  applied as (
    update public.speakers sp
       set person_id       = n.id,
           resolved_by     = 'live_tag',
           match_delta_ms  = w.best_delta,
           competing_names = d.names
      from winner w
      join named n on n.lname = lower(w.name)
      join disagreements d on d.speaker_id = w.speaker_id
     where sp.id = w.speaker_id
       and sp.resolved_by <> 'manual'
    returning sp.id
  ),
  backlink as (
    update public.live_tags t
       set resolved_speaker_id = h.speaker_id
      from tag_hits h
     where t.id = h.tag_id
    returning t.id
  )
  select count(*) into v_updated from applied;

  return v_updated;
end;
$$;

-- ---------------------------------------------------------------------------
-- tag_problems: what the app needs to warn about, in one call.
--
--   kind = 'unmatched' -- this tap matched no turn at all; the name was lost
--   kind = 'conflict'  -- several people were tagged into one voice
-- ---------------------------------------------------------------------------
create or replace function public.tag_problems(
  p_meeting_id uuid,
  p_user_id    uuid default null
)
returns table (kind text, detail text, at_ms integer)
language plpgsql
stable
as $$
declare
  v_user uuid := public.effective_user(p_user_id);
begin
  return query
  select 'unmatched'::text, t.name, t.at_ms
  from public.live_tags t
  where t.meeting_id = p_meeting_id
    and t.user_id = v_user
    and t.resolved_speaker_id is null

  union all

  select 'conflict'::text,
         array_to_string(sp.competing_names, ', '),
         null::integer
  from public.speakers sp
  where sp.meeting_id = p_meeting_id
    and sp.user_id = v_user
    and array_length(sp.competing_names, 1) > 1

  order by 3 nulls last;
end;
$$;
