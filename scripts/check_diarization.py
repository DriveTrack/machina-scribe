"""Reads a gemini-3.5-transcribe response the same way ScribeCore does.

Deliberately mirrors GeminiResponse.swift / Transcript.swift rather than
calling into Swift: if the two agree on a real response, the Swift parser is
reading the live wire format correctly.
"""
import json
import sys


def millis(offset):
    if not offset.endswith("s"):
        return None
    try:
        return round(float(offset[:-1]) * 1000)
    except ValueError:
        return None


def words(payload):
    for step in payload.get("steps") or []:
        for content in step.get("content") or []:
            for ann in content.get("annotations") or []:
                if ann.get("type") != "word_info":
                    continue
                start = millis(ann.get("start_offset") or "")
                end = millis(ann.get("end_offset") or "")
                if ann.get("text") is None or start is None or end is None:
                    continue
                yield ann["text"], ann.get("speaker"), start, end


def turns(items, max_gap_ms=1500):
    out, buf = [], []
    for item in items:
        if buf:
            _, prev_spk, _, prev_end = buf[-1]
            if prev_spk != item[1] or item[2] - prev_end > max_gap_ms:
                out.append(buf)
                buf = []
        buf.append(item)
    if buf:
        out.append(buf)
    return out


def main(path):
    payload = json.load(open(path))
    if "error" in payload:
        print("API error:", json.dumps(payload["error"])[:400])
        return 1

    items = list(words(payload))
    if not items:
        print("FAIL  no word_info annotations in the response")
        print(json.dumps(payload)[:1200])
        return 1

    speakers = {s for _, s, _, _ in items if s}
    grouped = turns(items)

    print(f"PASS  {len(items)} words parsed")
    print(f"{'PASS' if len(speakers) >= 2 else 'FAIL'}  "
          f"{len(speakers)} distinct speaker(s): {sorted(speakers)}")
    print(f"PASS  grouped into {len(grouped)} turns\n")

    print("--- transcript as the app would store it ---")
    # Mirrors Transcript.SpeakerNaming: number by order of first appearance,
    # because the label spelling ("spk:0" live, "spk_1" in the docs) and its
    # base are both unreliable.
    naming = {}
    for turn in grouped:
        spk = turn[0][1] or "<unknown>"
        label = naming.setdefault(spk, f"Speaker {len(naming) + 1}")
        stamp = turn[0][2] // 1000
        text = " ".join(w for w, _, _, _ in turn)
        for mark in [",", ".", "?", "!", ";", ":"]:
            text = text.replace(" " + mark, mark)
        print(f"[{stamp // 60:02d}:{stamp % 60:02d}] {label}: {text}")

    return 0 if len(speakers) >= 2 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
