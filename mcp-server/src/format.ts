/** Turning database rows into text a model can read without extra parsing. */

export function timecode(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, '0');
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

export function duration(ms: number | null): string {
  if (ms == null) return 'unknown length';
  const mins = Math.round(ms / 60000);
  if (mins < 1) return 'under a minute';
  if (mins < 60) return `${mins} min`;
  const h = Math.floor(mins / 60);
  const rest = mins % 60;
  return rest === 0 ? `${h}h` : `${h}h ${rest}m`;
}

export function day(iso: string): string {
  return new Date(iso).toISOString().replace('T', ' ').slice(0, 16);
}

/**
 * Consecutive turns by one speaker are merged. Diarization emits a new turn on
 * every pause, so an unmerged transcript repeats the same name down the page
 * and buries the actual back-and-forth.
 */
export interface Line {
  idx: number;
  start_ms: number;
  speaker: string;
  text: string;
}

export function renderTranscript(lines: Line[], withTimestamps = true): string {
  const out: string[] = [];
  let current: { speaker: string; start: number; parts: string[] } | null = null;

  const flush = () => {
    if (!current) return;
    const stamp = withTimestamps ? `[${timecode(current.start)}] ` : '';
    out.push(`${stamp}${current.speaker}: ${current.parts.join(' ')}`);
  };

  for (const line of lines) {
    if (current && current.speaker === line.speaker) {
      current.parts.push(line.text.trim());
    } else {
      flush();
      current = { speaker: line.speaker, start: line.start_ms, parts: [line.text.trim()] };
    }
  }
  flush();
  return out.join('\n');
}
