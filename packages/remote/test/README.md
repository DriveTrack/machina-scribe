# Remote server tests

`oauth-flow.test.mjs` drives the whole authorization flow against a running
`wrangler dev`, the way a real MCP client would: discovery, dynamic client
registration, the login form, token exchange with PKCE, and then authenticated
MCP calls.

It also checks the two things that must never regress:

- an unauthenticated `/mcp` call is rejected
- a tampered `redirect_uri` cannot turn the login form into an open redirect

## Running

Needs the local Supabase stack up (`supabase start`, migrations applied, and a
user seeded), and `packages/remote/.dev.vars` pointing at it.

```bash
cd packages/remote && npx wrangler dev --port 8788   # in one shell
node test/oauth-flow.test.mjs                        # in another
```

The credentials in the script are the local test account, not real ones.
