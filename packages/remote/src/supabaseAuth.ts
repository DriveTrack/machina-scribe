/**
 * Authenticating the person at the other end of the OAuth flow.
 *
 * The MCP server does not keep its own user table. It asks Supabase whether
 * these are valid credentials for *this* project, and takes the user id from
 * the answer. That id is what every query is then scoped to.
 */
export interface AuthedUser {
  id: string;
  email: string;
}

export async function signIn(
  supabaseUrl: string,
  anonKey: string,
  email: string,
  password: string
): Promise<AuthedUser> {
  const response = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: {
      apikey: anonKey,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ email, password })
  });

  if (!response.ok) {
    // Deliberately vague: distinguishing "no such account" from "wrong
    // password" tells an attacker which addresses are worth guessing at.
    throw new SignInError('That email and password did not match.');
  }

  const body = (await response.json()) as { user?: { id?: string; email?: string } };
  const id = body.user?.id;
  if (!id) throw new SignInError('Supabase did not return a user.');

  return { id, email: body.user?.email ?? email };
}

export class SignInError extends Error {}
