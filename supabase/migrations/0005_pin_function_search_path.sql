-- Pin search_path on every function in public.
--
-- Without an explicit setting a function resolves unqualified names against
-- whatever search_path the *caller* happens to have. A caller who can create a
-- schema can therefore put their own table or operator ahead of the one the
-- body meant, and the function runs their code instead. These are all SECURITY
-- INVOKER, so the attacker gains no privilege they did not already have -- but
-- the behaviour is still theirs to steer, and Supabase's linter flags it
-- (0011_function_search_path_mutable).
--
-- `= ''` rather than `= public, pg_temp`: every body here already schema-
-- qualifies its own tables (public.live_tags) and its Supabase calls
-- (auth.uid()), and everything else they touch -- now(), coalesce(),
-- array_to_string(), the tsvector operators -- lives in pg_catalog, which is
-- searched implicitly whatever search_path says. So the empty path costs
-- nothing and leaves no room to inject a schema at all.
--
-- Set on the identity argument list, not the name, because these are
-- overloadable and ALTER FUNCTION needs to know which one.

alter function public.effective_user(uuid)                       set search_path = '';
alter function public.touch_updated_at()                         set search_path = '';
alter function public.name_speaker(uuid, text, text, uuid)       set search_path = '';
alter function public.resolve_live_tags(uuid, integer, uuid)     set search_path = '';
alter function public.tag_problems(uuid, uuid)                   set search_path = '';
alter function public.search_transcripts(text, text, integer, uuid) set search_path = '';
alter function public.action_items(uuid, timestamptz, text)      set search_path = '';
