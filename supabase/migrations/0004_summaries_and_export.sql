-- A summary is more useful as parts than as prose: action items want owners,
-- decisions want to be listed, and Notion wants to lay them out as blocks.
-- `summary` keeps the readable paragraph (it is what listings and MCP show);
-- `summary_json` keeps the structure behind it.

alter table public.meetings
  add column if not exists summary_json jsonb,
  add column if not exists summarized_at timestamptz;

-- Where this meeting ended up in Notion, so it is not exported twice and the
-- app can link straight to it.
alter table public.meetings
  add column if not exists notion_page_id text,
  add column if not exists notion_url text,
  add column if not exists exported_at timestamptz;

-- Attendees named before the meeting starts. Kept per meeting rather than
-- inferred from tags, so the tagging pad can be short and specific even before
-- anyone has spoken.
create table if not exists public.meeting_attendees (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  meeting_id uuid not null references public.meetings(id) on delete cascade,
  person_id  uuid references public.people(id) on delete set null,
  name       text not null,
  created_at timestamptz not null default now(),
  unique (meeting_id, name)
);

create index if not exists meeting_attendees_meeting_idx
  on public.meeting_attendees (meeting_id);

alter table public.meeting_attendees enable row level security;

create policy meeting_attendees_owner on public.meeting_attendees
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- action_items: every open commitment across meetings, flattened out of the
-- summaries so Claude can answer "what did I agree to?" in one call.
-- ---------------------------------------------------------------------------
create or replace function public.action_items(
  p_user_id uuid default null,
  p_since   timestamptz default null,
  p_owner   text default null
)
returns table (
  meeting_id    uuid,
  meeting_title text,
  started_at    timestamptz,
  task          text,
  owner         text,
  due           text
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
    item ->> 'task',
    nullif(item ->> 'owner', ''),
    nullif(item ->> 'due', '')
  from public.meetings m
  cross join lateral jsonb_array_elements(
    coalesce(m.summary_json -> 'action_items', '[]'::jsonb)
  ) as item
  where m.user_id = v_user
    and (p_since is null or m.started_at >= p_since)
    and (p_owner is null or lower(coalesce(item ->> 'owner', '')) = lower(btrim(p_owner)))
  order by m.started_at desc;
end;
$$;
