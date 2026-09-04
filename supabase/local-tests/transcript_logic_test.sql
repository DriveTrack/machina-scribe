\set ON_ERROR_STOP on
\set m '22222222-2222-2222-2222-222222222222'
\set u '11111111-1111-1111-1111-111111111111'
begin;
insert into auth.users(id) values (:'u');
insert into auth._session(uid) values (:'u');
insert into public.meetings (id,user_id,title,source,status,started_at)
values (:'m',:'u','Roadmap sync','ios','ready',now());
insert into public.speakers (id,user_id,meeting_id,label) values
 ('a0000000-0000-0000-0000-000000000001',:'u',:'m','Speaker 1'),
 ('a0000000-0000-0000-0000-000000000002',:'u',:'m','Speaker 2'),
 ('a0000000-0000-0000-0000-000000000003',:'u',:'m','Speaker 3');
insert into public.segments (user_id,meeting_id,speaker_id,idx,start_ms,end_ms,text) values
 (:'u',:'m','a0000000-0000-0000-0000-000000000001',0,0,5000,'Lets start with the roadmap for next quarter.'),
 (:'u',:'m','a0000000-0000-0000-0000-000000000002',1,5000,12000,'I think we should push the migration back.'),
 (:'u',:'m','a0000000-0000-0000-0000-000000000003',2,12000,20000,'Latency numbers are the blocker, not the migration.'),
 (:'u',:'m','a0000000-0000-0000-0000-000000000001',3,22000,25000,'Agreed, lets get the latency work scoped.'),
 (:'u',:'m','a0000000-0000-0000-0000-000000000002',4,25000,30000,'I can own the scoping doc by Friday.');
insert into public.live_tags (user_id,meeting_id,name,at_ms) values
 (:'u',:'m','Jose',3000),(:'u',:'m','Alice',8000),(:'u',:'m','Bob',21000);

\echo '=== TEST 1: one tap per person resolves the whole meeting ==='
select public.resolve_live_tags(:'m') as named;
select idx, speaker, resolved_by from public.transcript_lines where meeting_id=:'m' order by idx;

\echo '=== TEST 2: gap tap (21000, tie by raw distance) picks the PRECEDING turn ==='
select label, match_delta_ms, (select name from public.people p where p.id=sp.person_id) as person
from public.speakers sp where meeting_id=:'m' and label='Speaker 3';

\echo '=== TEST 3: manual rename survives a re-run of tag resolution ==='
select public.name_speaker(:'m','Speaker 2','Alicia Reyes') is not null as renamed;
select public.resolve_live_tags(:'m') as named_again;
select distinct speaker, resolved_by from public.transcript_lines where meeting_id=:'m' and speaker_label='Speaker 2';

\echo '=== TEST 4: full-text search, and search scoped to one person ==='
select speaker, left(text,44) as text, round(rank::numeric,4) as rank from public.search_transcripts('latency');
\echo '-- scoped to Bob --'
select speaker, left(text,44) as text from public.search_transcripts('latency', 'Bob');
rollback;
