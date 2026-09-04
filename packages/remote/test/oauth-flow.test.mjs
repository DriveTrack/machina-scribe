import crypto from 'node:crypto';
const BASE = 'http://127.0.0.1:8788';
const ok = (label, cond, extra='') => console.log(`${cond ? 'PASS' : 'FAIL'}  ${label}${extra?' — '+extra:''}`);

// 1. Discovery
const meta = await (await fetch(`${BASE}/.well-known/oauth-authorization-server`)).json();
ok('discovery advertises endpoints',
   !!meta.authorization_endpoint && !!meta.token_endpoint && !!meta.registration_endpoint);
ok('PKCE S256 required', (meta.code_challenge_methods_supported||[]).includes('S256'));

// 2. Dynamic client registration (what Claude does on its own)
const reg = await (await fetch(`${BASE}/register`, {
  method:'POST', headers:{'Content-Type':'application/json'},
  body: JSON.stringify({
    client_name:'Claude (test)',
    redirect_uris:['https://claude.ai/api/mcp/auth_callback'],
    token_endpoint_auth_method:'none', grant_types:['authorization_code','refresh_token'],
    response_types:['code']
  })
})).json();
ok('dynamic client registration', !!reg.client_id, reg.client_id?.slice(0,12));

// 3. Authorize -> login page
const verifier = crypto.randomBytes(32).toString('base64url');
const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
const authUrl = `${BASE}/authorize?response_type=code&client_id=${encodeURIComponent(reg.client_id)}`
  + `&redirect_uri=${encodeURIComponent('https://claude.ai/api/mcp/auth_callback')}`
  + `&code_challenge=${challenge}&code_challenge_method=S256&state=xyz&scope=`;
const page = await fetch(authUrl);
const html = await page.text();
ok('authorize renders a login form', page.status===200 && html.includes('<form'));
ok('login page names the requesting client', html.includes('Claude (test)'));

const authRequest = html.match(/name="auth_request" value="([^"]*)"/)?.[1]
  ?.replace(/&quot;/g,'"').replace(/&#39;/g,"'").replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&');

// 4. Wrong password must not authenticate
const bad = await fetch(`${BASE}/authorize`, {
  method:'POST', redirect:'manual',
  headers:{'Content-Type':'application/x-www-form-urlencoded'},
  body:new URLSearchParams({email:'scribe-test@example.com', password:'wrong', auth_request:authRequest})
});
ok('bad password is rejected', bad.status===401);

// 5. Tampered redirect_uri must not become an open redirect
const tampered = JSON.parse(authRequest);
tampered.redirectUri = 'https://evil.example.com/steal';
const eviled = await fetch(`${BASE}/authorize`, {
  method:'POST', redirect:'manual',
  headers:{'Content-Type':'application/x-www-form-urlencoded'},
  body:new URLSearchParams({email:'scribe-test@example.com', password:'test-password-123',
                            auth_request:JSON.stringify(tampered)})
});
await eviled.text();
// The only thing that matters is that no redirect to the attacker was issued.
// (The body is irrelevant: an error page may legitimately echo the request.)
const evilLoc = eviled.headers.get('location') ?? 'none';
ok('unregistered redirect refused',
   eviled.status !== 302 && !evilLoc.includes('evil.example.com'),
   'status ' + eviled.status + ', location ' + evilLoc);

// 6. Real login
const good = await fetch(`${BASE}/authorize`, {
  method:'POST', redirect:'manual',
  headers:{'Content-Type':'application/x-www-form-urlencoded'},
  body:new URLSearchParams({email:'scribe-test@example.com', password:'test-password-123', auth_request:authRequest})
});
const location = good.headers.get('location') ?? '';
const code = new URL(location).searchParams.get('code');
ok('valid login issues an auth code', !!code);
ok('state round-trips', new URL(location).searchParams.get('state')==='xyz');

// 7. Token exchange
const tok = await (await fetch(`${BASE}/token`, {
  method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'},
  body:new URLSearchParams({grant_type:'authorization_code', code,
    redirect_uri:'https://claude.ai/api/mcp/auth_callback',
    client_id:reg.client_id, code_verifier:verifier})
})).json();
ok('token exchange with PKCE', !!tok.access_token);

// 8. MCP requires a token
const noAuth = await fetch(`${BASE}/mcp`, {
  method:'POST', headers:{'Content-Type':'application/json', 'Accept':'application/json, text/event-stream'},
  body: JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',
    params:{protocolVersion:'2025-06-18',capabilities:{},clientInfo:{name:'t',version:'0'}}})
});
ok('unauthenticated MCP call rejected', noAuth.status===401, `status ${noAuth.status}`);

// 9. Authenticated MCP session
const H = {'Content-Type':'application/json','Accept':'application/json, text/event-stream',
           'Authorization':`Bearer ${tok.access_token}`};
const parse = async r => {
  const t = await r.text();
  const line = t.split('\n').find(l=>l.startsWith('data: '));
  return JSON.parse(line ? line.slice(6) : t);
};
const initRes = await fetch(`${BASE}/mcp`, {method:'POST', headers:H,
  body: JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',
    params:{protocolVersion:'2025-06-18',capabilities:{},clientInfo:{name:'t',version:'0'}}})});
const sid = initRes.headers.get('mcp-session-id');
const initBody = await parse(initRes);
ok('initialize', initBody.result?.serverInfo?.name === 'machina-scribe');

const H2 = {...H, ...(sid ? {'mcp-session-id':sid} : {})};
await fetch(`${BASE}/mcp`, {method:'POST', headers:H2,
  body: JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})});

const tools = await parse(await fetch(`${BASE}/mcp`, {method:'POST', headers:H2,
  body: JSON.stringify({jsonrpc:'2.0',id:2,method:'tools/list',params:{}})}));
const names = (tools.result?.tools ?? []).map(t=>t.name);
ok('tools/list', names.length===6, names.join(', '));

const call = await parse(await fetch(`${BASE}/mcp`, {method:'POST', headers:H2,
  body: JSON.stringify({jsonrpc:'2.0',id:3,method:'tools/call',
    params:{name:'get_transcript',arguments:{meeting_id:'33333333-3333-3333-3333-333333333333'}}})}));
const text = call.result?.content?.[0]?.text ?? JSON.stringify(call.error);
ok('tools/call returns the real transcript', text.includes('Marcus Webb') && text.includes('Priya'));
console.log('\n--- transcript over authenticated remote MCP ---\n' + text);
