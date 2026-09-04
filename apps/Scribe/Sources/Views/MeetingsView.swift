import SwiftUI

struct MeetingsView: View {
    @Environment(AppState.self) private var app
    @State private var meetings: [Meeting] = []
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Text(loadError).foregroundStyle(.secondary)
            }
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
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
