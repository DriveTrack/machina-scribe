#!/usr/bin/env bash
# Applies the migrations to a throwaway Postgres and runs the SQL tests.
# Needs Docker. Touches nothing in the real Supabase project.
set -euo pipefail
cd "$(dirname "$0")/.."

C=scribe-pgtest
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=test postgres:16 >/dev/null
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 30); do
  docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

run() { docker cp "$1" "$C:/tmp/x.sql" >/dev/null; docker exec "$C" psql -U postgres -v ON_ERROR_STOP=1 -q -f /tmp/x.sql; }

# auth.users / auth.uid() stand-ins, since vanilla Postgres has no Supabase auth
run supabase/local-tests/auth_shim.sql
for m in supabase/migrations/*.sql; do echo "-- applying $m"; run "$m"; done
run supabase/local-tests/transcript_logic_test.sql
run supabase/local-tests/tag_problems_test.sql
echo "OK"
