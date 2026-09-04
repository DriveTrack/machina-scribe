#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import * as z from 'zod/v4';

import { loadEnv } from './env.js';
import { Store } from './db.js';
import { day, duration, renderTranscript, timecode } from './format.js';

const text = (body: string) => ({ content: [{ type: 'text' as const, text: body }] });

serveStdio(() => {
  const store = new Store(loadEnv());
  const server = new McpServer({ name: 'machina-scribe', version: '0.1.0' });

  server.registerTool(
    'list_meetings',
    {
      description:
        'List recorded meetings, newest first, with their length and who spoke. ' +
        'Start here when the user refers to a meeting without giving an id.',
      inputSchema: z.object({
        limit: z.number().int().min(1).max(100).default(20),
        since: z.string().optional().describe('ISO date; only meetings at or after this'),
        until: z.string().optional().describe('ISO date; only meetings at or before this'),
        title_contains: z.string().optional()
      })
    },
    async ({ limit, since, until, title_contains }) => {
      const meetings = await store.listMeetings({ limit, since, until, titleContains: title_contains });
      if (meetings.length === 0) return text('No meetings match.');

      const blocks = await Promise.all(
        meetings.map(async m => {
          const lines = await store.getLines(m.id);
          const speakers = [...new Set(lines.map(l => l.speaker))];
          const head = `${m.title ?? 'Untitled'}  (${m.id})`;
          const meta = [day(m.started_at), duration(m.duration_ms), m.source ?? 'unknown device']
            .concat(m.status === 'ready' ? [] : [`status: ${m.status}`])
            .join(' · ');
          const who = speakers.length ? `speakers: ${speakers.join(', ')}` : 'no transcript yet';
          return `${head}\n  ${meta}\n  ${who}`;
        })
      );
      return text(blocks.join('\n\n'));
    }
  );

  server.registerTool(
    'get_transcript',
    {
      description:
        'Full speaker-attributed transcript of one meeting. Consecutive turns by ' +
        'the same person are merged for readability.',
      inputSchema: z.object({
        meeting_id: z.string(),
        timestamps: z.boolean().default(true)
      })
    },
    async ({ meeting_id, timestamps }) => {
      const meeting = await store.getMeeting(meeting_id);
      if (!meeting) return text(`No meeting with id ${meeting_id}.`);

      const lines = await store.getLines(meeting_id);
      if (lines.length === 0) {
        return text(
          `"${meeting.title ?? 'Untitled'}" has no transcript yet (status: ${meeting.status}).`
        );
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
      const unnamed = await store.unnamedSpeakers(meeting_id);
      if (unnamed.length > 0) {
        header.push(
          '',
          `_Not yet identified: ${unnamed.join(', ')}. Use name_speaker to attach a name; ` +
            `it relabels every turn by that voice at once._`
        );
      }

      return text(`${header.join('\n')}\n\n${renderTranscript(lines, timestamps)}`);
    }
  );

  server.registerTool(
    'search_transcripts',
    {
      description:
        'Full-text search across every meeting. Optionally restrict to what one ' +
        'person said. Returns matching turns with meeting id and timecode.',
      inputSchema: z.object({
        query: z.string().describe('Words to find; supports quoted phrases and -exclusion'),
        person: z.string().optional().describe('Only turns spoken by this person'),
        limit: z.number().int().min(1).max(200).default(30)
      })
    },
    async ({ query, person, limit }) => {
      const hits = await store.search(query, person, limit);
      if (hits.length === 0) {
        return text(person ? `Nothing from ${person} matching "${query}".` : `No matches for "${query}".`);
      }
      const body = hits
        .map(
          h =>
            `${h.meeting_title ?? 'Untitled'} · ${day(h.started_at)} · [${timecode(h.start_ms)}]\n` +
            `  ${h.speaker}: ${h.text}\n  meeting_id: ${h.meeting_id}`
        )
        .join('\n\n');
      return text(`${hits.length} match${hits.length === 1 ? '' : 'es'}:\n\n${body}`);
    }
  );

  server.registerTool(
    'list_people',
    {
      description: 'Everyone who has been named as a speaker across all meetings.',
      inputSchema: z.object({})
    },
    async () => {
      const people = await store.listPeople();
      if (people.length === 0) return text('Nobody has been named yet.');
      return text(people.map(p => (p.note ? `${p.name} — ${p.note}` : p.name)).join('\n'));
    }
  );

  server.registerTool(
    'name_speaker',
    {
      description:
        'Attach a name to one diarized voice in a meeting. This renames every turn ' +
        'by that voice at once, and overrides any name inferred from a live tag. ' +
        'Use it to correct attribution.',
      inputSchema: z.object({
        meeting_id: z.string(),
        speaker_label: z.string().describe('The diarization label, e.g. "Speaker 2"'),
        name: z.string()
      })
    },
    async ({ meeting_id, speaker_label, name }) => {
      await store.nameSpeaker(meeting_id, speaker_label, name);
      return text(`${speaker_label} is now ${name} for every turn in this meeting.`);
    }
  );

  server.registerTool(
    'set_meeting_summary',
    {
      description: 'Save a summary onto a meeting, so it shows up in later listings.',
      inputSchema: z.object({ meeting_id: z.string(), summary: z.string() })
    },
    async ({ meeting_id, summary }) => {
      const n = await store.setSummary(meeting_id, summary);
      return text(n === 0 ? `No meeting with id ${meeting_id}.` : 'Summary saved.');
    }
  );

  return server;
});
