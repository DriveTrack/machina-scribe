\set ON_ERROR_STOP on
\set m '44444444-4444-4444-4444-444444444444'
\set u '11111111-1111-1111-1111-111111111111'
begin;
insert into auth.users(id) values (:'u') on conflict do nothing;
delete from auth._session;
insert into auth._session(uid) values (:'u');

insert into public.meetings (id,user_id,title,source,status,started_at)
values (:'m',:'u','Testing session','macos','ready',now());

-- Reproduces a real recording: one long-held voice, a 13 second gap where
-- nothing was transcribed, then more of the same voice, then a second voice.
insert into public.speakers (id,user_id,meeting_id,label) values
 ('c0000000-0000-0000-0000-000000000001',:'u',:'m','Speaker 1'),
 ('c0000000-0000-0000-0000-000000000002',:'u',:'m','Speaker 2');
insert into public.segments (user_id,meeting_id,speaker_id,idx,start_ms,end_ms,text) values
 (:'u',:'m','c0000000-0000-0000-0000-000000000001',0,1400,7300,'Testing one two three.'),
 (:'u',:'m','c0000000-0000-0000-0000-000000000001',1,20400,21500,'Testing one two three.'),
 (:'u',:'m','c0000000-0000-0000-0000-000000000001',2,23700,26400,'Testing one two three.'),
 (:'u',:'m','c0000000-0000-0000-0000-000000000002',3,33800,36600,'Testing one two three.');

-- Three people tagged. Jose falls in the dead zone; Nia and Chris both end up
-- pointing at Speaker 1.
insert into public.live_tags (user_id,meeting_id,name,at_ms) values
 (:'u',:'m','Jose',13570),
 (:'u',:'m','Nia',16438),
 (:'u',:'m','Chris',18289);

select public.resolve_live_tags(:'m') as speakers_named;

\echo '=== a tag that matched nothing is reported, not dropped in silence ==='
select kind, detail, at_ms from public.tag_problems(:'m');

\echo '=== the voice records every name that competed for it ==='
select label, competing_names,
       (select name from public.people p where p.id = sp.person_id) as won
from public.speakers sp where meeting_id = :'m' order by label;

\echo '=== majority beats proximity: two taps for Nia outvote one closer Chris ==='
insert into public.live_tags (user_id,meeting_id,name,at_ms) values (:'u',:'m','Nia',21000);
select public.resolve_live_tags(:'m') as re_resolved;
select label, (select name from public.people p where p.id = sp.person_id) as won
from public.speakers sp where meeting_id = :'m' and label = 'Speaker 1';

\echo '=== re-running is idempotent, not additive ==='
select public.resolve_live_tags(:'m') as again;
select count(*) as conflicts from public.tag_problems(:'m') where kind = 'conflict';
rollback;
