import SwiftUI
import ScribeCore

/// Reads the transcript, and lets any still-unnamed voice be named.
///
/// Naming happens against the *speaker*, never a single line, which is what
/// makes one correction fix the whole meeting at once.
struct TranscriptView: View {
    let meetingId: UUID

    @Environment(AppState.self) private var app
    @State private var lines: [TranscriptLine] = []
    @State private var problems: [TagProblem] = []
    @State private var naming: String?
    @State private var nameField = ""
    @State private var isLoading = true
    @State private var audioURL: URL?
    @State private var audioExpiry: Date?
    @State private var playback = PlaybackController()
    @State private var summary: MeetingSummary?
    @State private var meeting: Meeting?
    @State private var working: String?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                summarySection
                if !problems.isEmpty { problemsBanner }
                if audioURL != nil { player }
                if !unnamedLabels.isEmpty { namingPrompt }

                ForEach(grouped, id: \.first!.idx) { group in
                    turn(group)
                }
            }
            .padding()
            // No `.textSelection` anywhere in here, deliberately.
            //
            // It hosts an AppKit SelectionOverlay behind each selectable Text.
            // Clicking a line set that view invalidating its intrinsic content
            // size, which forced a re-layout, which re-measured the overlay,
            // which invalidated again: 100% CPU and a window that never
            // repainted. Confirmed by bisection -- removing this one modifier
            // takes the same click from spinning forever to 0% CPU. Moving it
            // from the individual turns up to this container did NOT help; the
            // hosted overlay is still there either way.
            //
            // Copying is served by the toolbar button instead, which is what
            // people actually wanted selection for on a transcript this long.
            //
            // The width is one definite `maxWidth` too. It used to be
            // `.frame(maxWidth: 720)` wrapped in `.frame(maxWidth: .infinity)`,
            // and two competing proposals inside a ScrollView's LazyVStack
            // gave the hosted view no stable width to settle on.
            .frame(maxWidth: 720, alignment: .leading)
        }
        .scrollDisabled(false)
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
        .toolbar {
            ToolbarItem {
                Button {
                    copyTranscript()
                } label: {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                }
                .help("Copy the whole transcript, with speaker names")
                .disabled(lines.isEmpty)
            }
        }
        .task { await load() }
        .onDisappear { playback.stop() }
        // A real binding, not `.constant(naming != nil)`.
        //
        // SwiftUI dismisses an alert by writing `false` back through this
        // binding. A constant binding swallows that write, so `naming` stayed
        // non-nil, so the alert re-presented itself immediately -- and the app
        // span at 100% CPU inside the layout engine, re-laying out the alert's
        // text field forever. It froze the moment you tried to name a speaker.
        .alert("Who is this?", isPresented: Binding(
            get: { naming != nil },
            set: { presented in
                if !presented { naming = nil; nameField = "" }
            }
        )) {
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Unidentified voices")
                .font(.headline)
            Text("A long meeting is transcribed in parts, and someone who stays quiet across a part boundary can come back as a new voice. Assigning one of these to a person you already named merges them — every turn moves across at once.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(unnamedLabels, id: \.self) { label in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(label).font(.subheadline.weight(.semibold))
                        Text(sample(for: label))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if audioURL != nil {
                            Button {
                                if let at = firstStart(of: label) { playback.play(fromMs: at) }
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Hear this voice")
                        }
                    }
                    FlowLayout(spacing: 6) {
                        ForEach(knownNames, id: \.self) { person in
                            Button(person) {
                                Task { await assign(label: label, to: person) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Button("Someone else…") { naming = label; nameField = "" }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    /// People already attached to a voice in this meeting -- the likely answers.
    private var knownNames: [String] {
        Array(Set(lines.filter { $0.speaker != $0.speakerLabel }.map(\.speaker))).sorted()
    }

    /// The whole transcript on the clipboard, speaker names and timecodes
    /// included -- what selection was there for, without a hosted view per
    /// turn measuring itself in a loop.
    private func copyTranscript() {
        let text = grouped.map { group in
            "[\(group[0].timecode)] \(group[0].speaker): "
                + group.map(\.text).joined(separator: " ")
        }.joined(separator: "\n\n")

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        working = "Transcript copied."
    }

    private func firstStart(of label: String) -> Int? {
        lines.first { $0.speakerLabel == label }?.startMs
    }

    /// A few words this voice actually said, so it can be recognised without
    /// scrolling to find it.
    private func sample(for label: String) -> String {
        guard let line = lines.first(where: { $0.speakerLabel == label && $0.text.count > 25 })
                ?? lines.first(where: { $0.speakerLabel == label })
        else { return "" }
        return "“\(line.text.prefix(60))…”"
    }

    private func assign(label: String, to person: String) async {
        try? await app.store?.nameSpeaker(meeting: meetingId, label: label, name: person)
        await app.refreshPeople()
        await load()
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
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            isCurrentlyPlaying(group) ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Hearing the moment is the fastest way to place a voice.
            guard audioURL != nil else { return }
            playback.play(fromMs: group[0].startMs)
        }
    }

    private func isCurrentlyPlaying(_ group: [TranscriptLine]) -> Bool {
        guard playback.isPlaying, let last = group.last else { return false }
        return playback.positionMs >= group[0].startMs && playback.positionMs <= last.endMs
    }

    /// Shown only while the recording is still inside its retention window.
    private var player: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    playback.togglePlay()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Text("Tap any line to hear it")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Delete audio", role: .destructive) {
                    app.archive.discard(meetingId)
                    playback.stop()
                    audioURL = nil
                    audioExpiry = nil
                }
                .font(.caption)
            }

            if let audioExpiry {
                Text("Audio kept until \(audioExpiry, format: .dateTime.weekday().hour().minute()), then deleted automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Tags that could not be applied. Saying nothing here would leave a
    /// transcript looking confidently right while quietly missing a name.
    private var problemsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Some tags didn't land", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(problems) { problem in
                if problem.isConflict {
                    Text("**\(problem.detail ?? "Several people")** were all tagged into one voice. Whoever was tapped most often won. Usually this means the transcriber heard them as the same speaker — check the lines below and correct the name if needed.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("**\(problem.detail ?? "A tag")** at \(stamp(problem.atMs ?? 0)) didn't line up with any speech, so that name wasn't applied. It usually means the tap fell in a silence.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stamp(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func isUnnamed(_ line: TranscriptLine) -> Bool {
        line.speaker == line.speakerLabel
    }

    // MARK: - Summary and export

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Summary").font(.headline)
                Spacer()
                if let working {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(working).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button(summary == nil ? "Summarise" : "Redo") { Task { await summarise() } }
                        .disabled(lines.isEmpty || !app.hasGeminiKey)
                }
            }

            if let summary {
                Text(summary.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if !summary.actionItems.isEmpty {
                    listing("Action items") {
                        ForEach(summary.actionItems) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "square").foregroundStyle(.secondary)
                                Text(actionLine(item))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                }
                if !summary.decisions.isEmpty {
                    listing("Decisions") {
                        ForEach(summary.decisions, id: \.self) { bulletRow($0) }
                    }
                }
                if !summary.openQuestions.isEmpty {
                    listing("Open questions") {
                        ForEach(summary.openQuestions, id: \.self) { bulletRow($0) }
                    }
                }

                Divider()
                notionRow
            } else if working == nil {
                Text(app.hasGeminiKey
                     ? "Pull out the decisions and action items from this meeting."
                     : "Add a Gemini API key in Settings to summarise.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var notionRow: some View {
        if let url = meeting?.notionURL, let link = URL(string: url) {
            HStack {
                Label("Filed in Notion", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Spacer()
                Link("Open", destination: link).font(.callout)
                Button("Send again") { Task { await sendToNotion() } }.font(.caption)
            }
        } else if app.hasNotionKey, let destination = app.notionDestination {
            HStack {
                Text("Send to **\(destination.title)** in Notion")
                    .font(.callout)
                Spacer()
                Button("Send") { Task { await sendToNotion() } }
            }
        } else if app.hasNotionKey {
            Text("Pick a Notion database in Settings to file meetings there.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func actionLine(_ item: MeetingSummary.ActionItem) -> String {
        var line = item.task
        if let owner = item.owner, !owner.isEmpty { line += " — \(owner)" }
        if let due = item.due, !due.isEmpty { line += " (\(due))" }
        return line
    }

    @ViewBuilder
    private func listing<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func summarise() async {
        guard let summarizer = app.summarizer else { return }
        working = "Summarising"
        failure = nil
        defer { working = nil }
        do {
            let text = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            let result = try await summarizer.summarize(
                title: meeting?.title, transcript: text, notes: meeting?.notes
            )
            try await app.store?.saveSummary(meeting: meetingId, result)
            summary = result
            await applyGeneratedTitle(result)
            app.meetingsDidChange()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Put the date in front of the generated name: it keeps meetings sorting
    /// chronologically in a list and in Notion, while still saying what the
    /// meeting was. A title the user typed themselves is never overwritten.
    private func applyGeneratedTitle(_ summary: MeetingSummary) async {
        guard let meeting, meeting.hasOnlyDateTitle else { return }
        let name = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let dated = "\(Meeting.dateTitle(for: meeting.startedAt)) — \(name)"
        try? await app.store?.setTitle(meeting: meetingId, title: dated)
        self.meeting?.title = dated
    }

    private func sendToNotion() async {
        guard let notion = app.notion,
              let destination = app.notionDestination,
              let meeting
        else { return }

        working = "Sending to Notion"
        failure = nil
        defer { working = nil }
        do {
            let text = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            let result = try await notion.export(
                to: destination,
                title: meeting.displayTitle,
                startedAt: meeting.startedAt,
                durationMs: meeting.durationMs,
                speakers: Array(Set(lines.map(\.speaker))).sorted(),
                summary: summary,
                notes: meeting.notes,
                transcript: text
            )
            try await app.store?.recordNotionExport(
                meeting: meetingId, pageId: result.pageId, url: result.url
            )
            await load()
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        lines = (try? await app.store?.transcript(meeting: meetingId)) ?? []
        problems = (try? await app.store?.tagProblems(meeting: meetingId)) ?? []
        summary = try? await app.store?.summary(meeting: meetingId)
        meeting = try? await app.store?.meeting(meetingId)

        let archive = app.archive
        audioURL = archive.url(for: meetingId)
        audioExpiry = archive.expiry(for: meetingId)
        if let audioURL { playback.load(audioURL) }

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
