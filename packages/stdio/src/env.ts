/** Configuration, read once at startup so a missing key fails loudly. */
export interface Env {
  supabaseUrl: string;
  supabaseKey: string;
  /**
   * Whose transcripts this server serves. Required because the service-role
   * key bypasses row level security, so the scoping has to be explicit here
   * rather than inherited from a session.
   */
  userId: string;
}

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(
      `${name} is not set. See mcp-server/README.md for the four environment ` +
        `variables this server needs.`
    );
  }
  return value;
}

export function loadEnv(): Env {
  return {
    supabaseUrl: required('SUPABASE_URL'),
    supabaseKey: required('SUPABASE_SERVICE_ROLE_KEY'),
    userId: required('SCRIBE_USER_ID')
  };
}
