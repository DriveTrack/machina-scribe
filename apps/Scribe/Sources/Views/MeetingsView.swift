#if os(macOS)
import AppKit
#endif
import SwiftUI

struct MeetingsView: View {
    @Environment(AppState.self) private var app
    @State private var meetings: [Meeting] = []
    @State private var loadError: String?
    @State private var pending: [(meeting: UUID, url: URL, bytes: Int64)] = []
    @State private var busy: UUID?

    var body: some View {
        List {
            if let loadError {
                Text(loadError).foregroundStyle(.secondary)
            }
            if !pending.isEmpty { pendingSection }
            ForEach(meetings) { meeting in
                NavigationLink {
                    TranscriptView(meetingId: meeting.id)
                } label: {
                    row(meeting)
                }
            }
            .onDelete { offsets in
                let doomed = offsets.map { meetings[$0] }
                meetings.remove(atOffsets: offsets)
                Task {
                    for meeting in doomed { try? await app.store?.delete(meeting: meeting.id) }
                }
            }
        }
        .overlay {
            if meetings.isEmpty && loadError == nil {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "waveform",
                    description: Text("Recordings you finish will appear here.")
                )
            }
        }
        .navigationTitle("Meetings")
        .refreshable { await load() }
        // Keyed on the token so finishing a recording refreshes the list. On
        // macOS the sidebar is built once with the window and would otherwise
        // never reload.
        .task(id: app.meetingsToken) { await load() }
        .toolbar {
            Button {
                Task { await load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    /// Recordings that were captured but never got a transcript.
    ///
    /// These are the ones worth shouting about: the audio still exists and is
    /// recoverable, but only until someone deletes it.
    @ViewBuilder
    private var pendingSection: some View {
        Section {
            ForEach(pending, id: \.meeting) { item in
                let title = meetings.first { $0.id == item.meeting }?.displayTitle ?? "Recording"
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    Text("\(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)) of audio, not yet transcribed. Parts already done are reused, so this picks up where it stopped.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(busy == item.meeting ? "Transcribing…" : "Finish transcribing") {
                            Task { await finish(item.meeting) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy != nil)

                        Button("Reveal audio") {
                            #if os(macOS)
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            #endif
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("Waiting to be transcribed", systemImage: "exclamationmark.arrow.circlepath")
        }
    }

    private func finish(_ meeting: UUID) async {
        guard let session = app.session else { return }
        busy = meeting
        defer { busy = nil }
        let duration = meetings.first { $0.id == meeting }?.durationMs ?? 0
        await session.resume(meeting: meeting, durationMs: duration)
        await load()
    }

    private func row(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.displayTitle).font(.headline)
            HStack(spacing: 6) {
                Text(meeting.startedAt, format: .dateTime.month().day().hour().minute())
                if let ms = meeting.durationMs {
                    Text("·")
                    Text(lengthText(ms))
                }
                if meeting.status != "ready" {
                    Text("·")
                    Text(meeting.status)
                        .foregroundStyle(meeting.status == "failed" ? .orange : .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func lengthText(_ ms: Int) -> String {
        let minutes = max(1, ms / 60_000)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func load() async {
        do {
            meetings = try await app.store?.meetings() ?? []
            pending = app.archive.pendingMeetings()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
