import { OAuthProvider, type AuthRequest, type OAuthHelpers } from '@cloudflare/workers-oauth-provider';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { McpAgent } from 'agents/mcp';
import { Store, TOOLS } from '@scribe/mcp-core';

import { loginPage } from './login.js';
import { signIn, SignInError } from './supabaseAuth.js';

export interface Env {
  OAUTH_KV: KVNamespace;
  OAUTH_PROVIDER: OAuthHelpers;
  MCP_OBJECT: DurableObjectNamespace;
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
}

/** Carried on the grant, so every request knows whose transcripts to read. */
interface Props extends Record<string, unknown> {
  userId: string;
  email: string;
}

// ---------------------------------------------------------------------------
// The MCP server itself
// ---------------------------------------------------------------------------

export class ScribeMCP extends McpAgent<Env, never, Props> {
  server = new McpServer({ name: 'machina-scribe', version: '0.1.0' });

  async init() {
    // Reaching here without a grant would mean the OAuth layer let an
    // unauthenticated request through. Refuse rather than fall back to any
    // default identity.
    const userId = this.props?.userId;
    if (!userId) {
      throw new Error('No authenticated user on this session.');
    }

    // The service-role key bypasses row level security, so this id -- taken
    // from the OAuth grant, never from anything the caller sends -- is what
    // scopes the data. A client cannot ask for someone else's meetings.
    const store = new Store({
      supabaseUrl: this.env.SUPABASE_URL,
      supabaseKey: this.env.SUPABASE_SERVICE_ROLE_KEY,
      userId
    });

    for (const tool of TOOLS) {
      this.server.registerTool(
        tool.name,
        {
          description: tool.description,
          inputSchema: tool.inputShape,
          annotations: {
            readOnlyHint: tool.readOnly,
            openWorldHint: false
          }
        },
        async (args: Record<string, unknown>) => ({
          content: [{ type: 'text' as const, text: await tool.run(store, args) }]
        })
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Sign-in, which is everything the OAuth provider does not handle itself
// ---------------------------------------------------------------------------

/**
 * A tampered hidden field must not become an open redirect.
 *
 * `parseAuthRequest` validated the request on the way in, but the form round
 * trips it through the browser, so the redirect URI is checked again against
 * what the client actually registered before any code is issued.
 */
async function assertRegisteredRedirect(env: Env, authRequest: AuthRequest): Promise<void> {
  const client = await env.OAUTH_PROVIDER.lookupClient(authRequest.clientId);
  if (!client) throw new SignInError('Unknown client.');
  if (!client.redirectUris.includes(authRequest.redirectUri)) {
    throw new SignInError('This redirect address is not registered for that client.');
  }
}

const authHandler = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === '/authorize' && request.method === 'GET') {
      const authRequest = await env.OAUTH_PROVIDER.parseAuthRequest(request);
      const client = await env.OAUTH_PROVIDER.lookupClient(authRequest.clientId);
      return loginPage({
        authRequest,
        clientName: client?.clientName ?? 'An MCP client'
      });
    }

    if (url.pathname === '/authorize' && request.method === 'POST') {
      const form = await request.formData();
      const email = String(form.get('email') ?? '');
      const password = String(form.get('password') ?? '');

      let authRequest: AuthRequest;
      try {
        authRequest = JSON.parse(String(form.get('auth_request') ?? '')) as AuthRequest;
      } catch {
        return new Response('Malformed authorization request.', { status: 400 });
      }

      // A bad redirect means the request itself was tampered with, not that the
      // person mistyped a password. Fail flat rather than handing back a form
      // that carries the poisoned request for them to submit again.
      try {
        await assertRegisteredRedirect(env, authRequest);
      } catch {
        return new Response('This authorization request is not valid for that client.', {
          status: 401,
          headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' }
        });
      }

      const client = await env.OAUTH_PROVIDER.lookupClient(authRequest.clientId);

      try {
        const user = await signIn(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, email, password);

        const { redirectTo } = await env.OAUTH_PROVIDER.completeAuthorization({
          request: authRequest,
          userId: user.id,
          scope: authRequest.scope,
          metadata: { signedInAt: new Date().toISOString() },
          props: { userId: user.id, email: user.email } satisfies Props
        });
        return Response.redirect(redirectTo, 302);
      } catch (error) {
        return loginPage({
          authRequest,
          clientName: client?.clientName ?? 'An MCP client',
          error: error instanceof SignInError ? error.message : 'Could not sign you in.'
        });
      }
    }

    if (url.pathname === '/') {
      return new Response(
        'machina-scribe MCP server. Add it as a connector using this URL + /mcp',
        { headers: { 'Content-Type': 'text/plain; charset=utf-8' } }
      );
    }

    return new Response('Not found', { status: 404 });
  }
} satisfies ExportedHandler<Env>;

export default new OAuthProvider({
  apiRoute: '/mcp',
  apiHandler: ScribeMCP.serve('/mcp') as never,
  defaultHandler: authHandler as never,
  authorizeEndpoint: '/authorize',
  tokenEndpoint: '/token',
  // Claude registers itself rather than being configured by hand.
  clientRegistrationEndpoint: '/register'
});
