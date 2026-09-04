import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export interface StoreConfig {
  supabaseUrl: string;
  /** Service-role key. Bypasses RLS, so every query here filters by user id. */
  supabaseKey: string;
  /** Whose transcripts this store reads and writes. */
  userId: string;
}

export interface MeetingRow {
  id: string;
  title: string | null;
  location: string | null;
  started_at: string;
  duration_ms: number | null;
  source: string | null;
  status: string;
  summary: string | null;
  notes: string | null;
}

export interface LineRow {
  idx: number;
  start_ms: number;
  end_ms: number;
  speaker: string;
  speaker_label: string;
  resolved_by: string | null;
  text: string;
}

export interface ActionItemRow {
  meeting_id: string;
  meeting_title: string | null;
  started_at: string;
  task: string;
  owner: string | null;
  due: string | null;
}

export interface SearchRow {
  meeting_id: string;
  meeting_title: string | null;
  started_at: string;
  idx: number;
  start_ms: number;
  speaker: string;
  text: string;
}

export class Store {
  private readonly db: SupabaseClient;
  private readonly userId: string;

  constructor(config: StoreConfig) {
    this.db = createClient(config.supabaseUrl, config.supabaseKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });
    this.userId = config.userId;
  }

  private unwrap<T>(res: { data: T | null; error: { message: string } | null }): T {
    if (res.error) throw new Error(res.error.message);
    if (res.data === null) throw new Error('query returned no data');
    return res.data;
  }

  async listMeetings(opts: {
    limit: number;
    since?: string;
    until?: string;
    titleContains?: string;
  }): Promise<MeetingRow[]> {
    let q = this.db
      .from('meetings')
      .select('id,title,location,started_at,duration_ms,source,status,summary,notes')
      .eq('user_id', this.userId)
      .order('started_at', { ascending: false })
      .limit(opts.limit);

    if (opts.since) q = q.gte('started_at', opts.since);
    if (opts.until) q = q.lte('started_at', opts.until);
    if (opts.titleContains) q = q.ilike('title', `%${opts.titleContains}%`);

    return this.unwrap(await q);
  }

  async getMeeting(id: string): Promise<MeetingRow | null> {
    const { data, error } = await this.db
      .from('meetings')
      .select('id,title,location,started_at,duration_ms,source,status,summary,notes')
      .eq('user_id', this.userId)
      .eq('id', id)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data;
  }

  /**
   * PostgREST caps a response at 1000 rows unless a range is given, and gives
   * no indication that it truncated. A long meeting runs past that, so an
   * unpaged read hands back a transcript that just stops partway through --
   * which, for a summary or a search, silently loses the second half.
   */
  async getLines(meetingId: string): Promise<LineRow[]> {
    const pageSize = 1000;
    const all: LineRow[] = [];

    for (let offset = 0; ; offset += pageSize) {
      const page = this.unwrap<LineRow[]>(
        await this.db
          .from('transcript_lines')
          .select('idx,start_ms,end_ms,speaker,speaker_label,resolved_by,text')
          .eq('user_id', this.userId)
          .eq('meeting_id', meetingId)
          .order('idx', { ascending: true })
          .range(offset, offset + pageSize - 1)
      );
      all.push(...page);
      if (page.length < pageSize) return all;
    }
  }

  /** Voices in a meeting that nobody has put a name to yet. */
  async unnamedSpeakers(meetingId: string): Promise<string[]> {
    const rows = this.unwrap(
      await this.db
        .from('speakers')
        .select('label,person_id')
        .eq('user_id', this.userId)
        .eq('meeting_id', meetingId)
        .is('person_id', null)
        .order('label')
    );
    return rows.map((r: { label: string }) => r.label);
  }

  async search(query: string, person: string | undefined, limit: number): Promise<SearchRow[]> {
    return this.unwrap(
      await this.db.rpc('search_transcripts', {
        p_query: query,
        p_person: person ?? null,
        p_limit: limit,
        p_user_id: this.userId
      })
    );
  }

  async actionItems(opts: { owner?: string; since?: string }): Promise<ActionItemRow[]> {
    return this.unwrap(
      await this.db.rpc('action_items', {
        p_user_id: this.userId,
        p_owner: opts.owner ?? null,
        p_since: opts.since ?? null
      })
    );
  }

  async listPeople(): Promise<{ name: string; note: string | null }[]> {
    return this.unwrap(
      await this.db
        .from('people')
        .select('name,note')
        .eq('user_id', this.userId)
        .order('name')
    );
  }

  async nameSpeaker(meetingId: string, label: string, name: string): Promise<void> {
    const { error } = await this.db.rpc('name_speaker', {
      p_meeting_id: meetingId,
      p_label: label,
      p_name: name,
      p_user_id: this.userId
    });
    if (error) throw new Error(error.message);
  }

  async setSummary(meetingId: string, summary: string): Promise<number> {
    const { data, error } = await this.db
      .from('meetings')
      .update({ summary })
      .eq('user_id', this.userId)
      .eq('id', meetingId)
      .select('id');
    if (error) throw new Error(error.message);
    return data?.length ?? 0;
  }
}
