-- Minimal stand-in for the Supabase auth schema so migrations run on vanilla PG.
create schema if not exists auth;
create table auth.users (id uuid primary key);
create table auth._session (uid uuid);
create or replace function auth.uid() returns uuid language sql stable as
  $$ select uid from auth._session limit 1 $$;
