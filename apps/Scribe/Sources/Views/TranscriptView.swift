import SwiftUI

/// Reads the transcript, and lets any still-unnamed voice be named.
///
/// Naming happens against the *speaker*, never a single line, which is what
/// makes one correction fix the whole meeting at once.
struct TranscriptView: View {
    let meetingId: UUID

    @Environment(AppState.self) private var app
    @State private var lines: [TranscriptLine] = []
    @State private var naming: String?
    @State private var nameField = ""
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !unnamedLabels.isEmpty { namingPrompt }

                ForEach(grouped, id: \.first!.idx) { group in
                    turn(group)
                }
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if lines.isEmpty {
                ContentUnavailableView(
                    "No transcript",
                    systemImage: "text.badge.xmark",
                    description: Text("This meeting has no transcribed speech.")
                )
            }
        }
        .navigationTitle("Transcript")
        .task { await load() }
        .alert("Who is this?", isPresented: .constant(naming != nil)) {
            TextField("Name", text: $nameField)
            Button("Cancel", role: .cancel) { naming = nil; nameField = "" }
            Button("Save") { Task { await commitName() } }
        } message: {
            Text("Every turn by \(naming ?? "this voice") will be renamed.")
        }
    }

    // MARK: - Pieces

    /// Consecutive lines from one person read as a single paragraph; diarizers
    /// split on every breath, and the raw output is unreadable.
    private var grouped: [[TranscriptLine]] {
        lines.reduce(into: [[TranscriptLine]]()) { groups, line in
            if var last = groups.last, last.first?.speaker == line.speaker {
                last.append(line)
                groups[groups.count - 1] = last
            } else {
                groups.append([line])
            }
        }
    }

    private var unnamedLabels: [String] {
        let labels = lines
            .filter { $0.speaker == $0.speakerLabel }
            .compactMap(\.speakerLabel)
        return Array(Set(labels)).sorted()
    }

    private var namingPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Unidentified voices")
                .font(.headline)
            Text("Tap one to name it. The name applies to every turn that voice takes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(unnamedLabels, id: \.self) { label in
                    Button(label) { naming = label; nameField = "" }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func turn(_ group: [TranscriptLine]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(group[0].speaker)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isUnnamed(group[0]) ? .secondary : .primary)
                Text(group[0].timecode)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                if isUnnamed(group[0]) {
                    Button("Name") { naming = group[0].speakerLabel; nameField = "" }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text(group.map(\.text).joined(separator: " "))
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isUnnamed(_ line: TranscriptLine) -> Bool {
        line.speaker == line.speakerLabel
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        lines = (try? await app.store?.transcript(meeting: meetingId)) ?? []
        isLoading = false
    }

    private func commitName() async {
        guard let label = naming else { return }
        let name = nameField.trimmingCharacters(in: .whitespacesAndNewlines)
        naming = nil
        nameField = ""
        guard !name.isEmpty else { return }

        try? await app.store?.nameSpeaker(meeting: meetingId, label: label, name: name)
        await app.refreshPeople()
        await load()
    }
}
