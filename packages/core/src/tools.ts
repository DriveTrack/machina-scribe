import { z, type ZodRawShape } from 'zod';
import { Store } from './store.js';
import { day, duration, renderTranscript, timecode } from './format.js';

/**
 * One tool, defined once.
 *
 * The schema is a Zod *raw shape* rather than a wrapped object because the two
 * server entry points want it differently -- the stdio SDK wraps it, the Worker
 * SDK takes it as-is -- and a shape converts cleanly to both. Handlers return
 * plain strings; each entry point wraps them in its own content envelope.
 */
export interface ToolSpec {
  name: string;
  description: string;
  inputShape: ZodRawShape;
  /** False for the two tools that write, so the remote server can gate them. */
  readOnly: boolean;
  run(store: Store, args: Record<string, unknown>): Promise<string>;
}

export const TOOLS: ToolSpec[] = [
  {
    name: 'list_meetings',
    description:
      'List recorded meetings, newest first, with their length and who spoke. ' +
      'Start here when the user refers to a meeting without giving an id.',
    readOnly: true,
    inputShape: {
      limit: z.number().int().min(1).max(100).default(20),
      since: z.string().optional().describe('ISO date; only meetings at or after this'),
      until: z.string().optional().describe('ISO date; only meetings at or before this'),
      title_contains: z.string().optional()
    },
    async run(store, args) {
      const meetings = await store.listMeetings({
        limit: (args.limit as number) ?? 20,
        since: args.since as string | undefined,
        until: args.until as string | undefined,
        titleContains: args.title_contains as string | undefined
      });
      if (meetings.length === 0) return 'No meetings match.';

      const blocks = await Promise.all(
        meetings.map(async m => {
          const lines = await store.getLines(m.id);
          const speakers = [...new Set(lines.map(l => l.speaker))];
          const meta = [day(m.started_at), duration(m.duration_ms), m.source ?? 'unknown device']
            .concat(m.status === 'ready' ? [] : [`status: ${m.status}`])
            .join(' · ');
          const who = speakers.length ? `speakers: ${speakers.join(', ')}` : 'no transcript yet';
          return `${m.title ?? 'Untitled'}  (${m.id})\n  ${meta}\n  ${who}`;
        })
      );
      return blocks.join('\n\n');
    }
  },

  {
    name: 'get_transcript',
    description:
      'Full speaker-attributed transcript of one meeting. Consecutive turns by ' +
      'the same person are merged for readability.',
    readOnly: true,
    inputShape: {
      meeting_id: z.string(),
      timestamps: z.boolean().default(true)
    },
    async run(store, args) {
      const id = args.meeting_id as string;
      const meeting = await store.getMeeting(id);
      if (!meeting) return `No meeting with id ${id}.`;

      const lines = await store.getLines(id);
      if (lines.length === 0) {
        return `"${meeting.title ?? 'Untitled'}" has no transcript yet (status: ${meeting.status}).`;
      }

      const header = [
        `# ${meeting.title ?? 'Untitled'}`,
        [day(meeting.started_at), duration(meeting.duration_ms), meeting.location]
          .filter(Boolean)
          .join(' · ')
      ];
      if (meeting.summary) header.push('', `**Summary:** ${meeting.summary}`);
      if (meeting.notes) header.push('', `**Typed notes:** ${meeting.notes}`);

      // Say so plainly rather than letting a bare "Speaker 2" read as a name.
      const unnamed = await store.unnamedSpeakers(id);
      if (unnamed.length > 0) {
        header.push(
          '',
          `_Not yet identified: ${unnamed.join(', ')}. Use name_speaker to attach a name; ` +
            `it relabels every turn by that voice at once._`
        );
      }

      const withStamps = (args.timestamps as boolean) ?? true;
      return `${header.join('\n')}\n\n${renderTranscript(lines, withStamps)}`;
    }
  },

  {
    name: 'search_transcripts',
    description:
      'Full-text search across every meeting. Optionally restrict to what one ' +
      'person said. Returns matching turns with meeting id and timecode.',
    readOnly: true,
    inputShape: {
      query: z.string().describe('Words to find; supports quoted phrases and -exclusion'),
      person: z.string().optional().describe('Only turns spoken by this person'),
      limit: z.number().int().min(1).max(200).default(30)
    },
    async run(store, args) {
      const query = args.query as string;
      const person = args.person as string | undefined;
      const hits = await store.search(query, person, (args.limit as number) ?? 30);
      if (hits.length === 0) {
        return person ? `Nothing from ${person} matching "${query}".` : `No matches for "${query}".`;
      }
      const body = hits
        .map(
          h =>
            `${h.meeting_title ?? 'Untitled'} · ${day(h.started_at)} · [${timecode(h.start_ms)}]\n` +
            `  ${h.speaker}: ${h.text}\n  meeting_id: ${h.meeting_id}`
        )
        .join('\n\n');
      return `${hits.length} match${hits.length === 1 ? '' : 'es'}:\n\n${body}`;
    }
  },

  {
    name: 'list_people',
    description: 'Everyone who has been named as a speaker across all meetings.',
    readOnly: true,
    inputShape: {},
    async run(store) {
      const people = await store.listPeople();
      if (people.length === 0) return 'Nobody has been named yet.';
      return people.map(p => (p.note ? `${p.name} — ${p.note}` : p.name)).join('\n');
    }
  },

  {
    name: 'action_items',
    description:
      'Everything anyone committed to across meetings, pulled from the summaries. ' +
      'Use for "what did I agree to", "what does Priya owe me", or chasing follow-ups. ' +
      'Only covers meetings that have been summarised.',
    readOnly: true,
    inputShape: {
      owner: z.string().optional().describe('Only items owned by this person'),
      since: z.string().optional().describe('ISO date; only meetings at or after this')
    },
    async run(store, args) {
      const items = await store.actionItems({
        owner: args.owner as string | undefined,
        since: args.since as string | undefined
      });
      if (items.length === 0) {
        return args.owner
          ? `Nothing outstanding for ${args.owner}.`
          : 'No action items recorded. Meetings need to be summarised first.';
      }
      return items
        .map(item => {
          const bits = [item.task];
          if (item.owner) bits.push(`owner: ${item.owner}`);
          if (item.due) bits.push(`due: ${item.due}`);
          return `${bits.join(' · ')}\n  from "${item.meeting_title ?? 'Untitled'}" on ${day(item.started_at)}` +
                 `\n  meeting_id: ${item.meeting_id}`;
        })
        .join('\n\n');
    }
  },

  {
    name: 'name_speaker',
    description:
      'Attach a name to one diarized voice in a meeting. This renames every turn ' +
      'by that voice at once, and overrides any name inferred from a live tag. ' +
      'Use it to correct attribution.',
    readOnly: false,
    inputShape: {
      meeting_id: z.string(),
      speaker_label: z.string().describe('The diarization label, e.g. "Speaker 2"'),
      name: z.string()
    },
    async run(store, args) {
      await store.nameSpeaker(
        args.meeting_id as string,
        args.speaker_label as string,
        args.name as string
      );
      return `${args.speaker_label} is now ${args.name} for every turn in this meeting.`;
    }
  },

  {
    name: 'set_meeting_summary',
    description: 'Save a summary onto a meeting, so it shows up in later listings.',
    readOnly: false,
    inputShape: {
      meeting_id: z.string(),
      summary: z.string()
    },
    async run(store, args) {
      const id = args.meeting_id as string;
      const n = await store.setSummary(id, args.summary as string);
      return n === 0 ? `No meeting with id ${id}.` : 'Summary saved.';
    }
  }
];
