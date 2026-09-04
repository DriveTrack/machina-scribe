import type { AuthRequest } from '@cloudflare/workers-oauth-provider';

/** Anything interpolated into the page gets escaped; some of it is attacker-controlled. */
function esc(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

const STYLE = `
:root { color-scheme: light dark; --bg:#f6f6f7; --card:#fff; --ink:#16161a;
        --muted:#6b6b76; --line:#e3e3e8; --accent:#2f6df6; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#111114; --card:#1a1a1f; --ink:#f2f2f4; --muted:#9a9aa5; --line:#2c2c34; }
}
* { box-sizing: border-box; }
body { margin:0; min-height:100vh; display:grid; place-items:center; background:var(--bg);
       color:var(--ink); font:15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
       padding:24px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:14px;
        padding:28px; width:100%; max-width:380px; }
h1 { font-size:19px; margin:0 0 6px; letter-spacing:-0.01em; }
p.sub { margin:0 0 22px; color:var(--muted); font-size:13.5px; }
label { display:block; font-size:12.5px; font-weight:600; margin:14px 0 5px; }
input { width:100%; padding:10px 12px; border:1px solid var(--line); border-radius:8px;
        background:var(--bg); color:var(--ink); font-size:15px; }
input:focus { outline:2px solid var(--accent); outline-offset:-1px; border-color:transparent; }
button { width:100%; margin-top:22px; padding:11px; border:0; border-radius:8px;
         background:var(--accent); color:#fff; font-size:15px; font-weight:600; cursor:pointer; }
button:hover { filter:brightness(1.08); }
.err { margin:16px 0 0; padding:10px 12px; border-radius:8px; font-size:13.5px;
       background:color-mix(in srgb, #d23 12%, transparent); color:#d23; }
.note { margin-top:20px; padding-top:16px; border-top:1px solid var(--line);
        color:var(--muted); font-size:12.5px; }
`;

export function loginPage(opts: {
  authRequest: AuthRequest;
  clientName: string;
  error?: string;
}): Response {
  const payload = esc(JSON.stringify(opts.authRequest));

  const html = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in — machina-scribe</title>
<style>${STYLE}</style>
</head><body>
  <form class="card" method="POST" action="/authorize">
    <h1>Connect to your transcripts</h1>
    <p class="sub"><strong>${esc(opts.clientName)}</strong> is asking to read your
       meeting transcripts. Sign in with the account you use in the Scribe app.</p>

    ${opts.error ? `<div class="err">${esc(opts.error)}</div>` : ''}

    <label for="email">Email</label>
    <input id="email" name="email" type="email" autocomplete="username" required autofocus>

    <label for="password">Password</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required>

    <input type="hidden" name="auth_request" value="${payload}">
    <button type="submit">Sign in and allow</button>

    <p class="note">Your password goes to your own Supabase project to be checked,
       and is never stored here.</p>
  </form>
</body></html>`;

  return new Response(html, {
    status: opts.error ? 401 : 200,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      // The page embeds no scripts and must not be framed.
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff'
    }
  });
}
