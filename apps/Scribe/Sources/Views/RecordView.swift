import SwiftUI

/// The in-meeting screen. Everything here is sized to be hit without looking:
/// during a real conversation you glance down for half a second at most.
struct RecordView: View {
    @Environment(AppState.self) private var app

    @State private var title = ""
    @State private var newName = ""
    @State private var showingAddPerson = false
    /// Set when the name is being added for a line of preview text rather than
    /// for whoever is talking right now.
    @State private var pendingChunkMs: Int?
    @State private var rosterName = ""

    private var session: RecordingSession? { app.session }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                meter
                if session?.isRecording != true { roster }
                controls
                if session?.isRecording == true {
                    taggingPad
                    livePreview
                }
                if let phase = session?.phase { status(phase) }
            }
            .padding()
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Record")
        .task { await app.refreshPeople() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 8) {
            TextField("Meeting title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .disabled(session?.isRecording == true)

            Text(elapsedText)
                .font(.system(size: 46, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.top, 12)
    }

    private var elapsedText: String {
        let seconds = Int(session?.recorder.elapsed.components.seconds ?? 0)
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// A level meter, not a waveform: the only question it answers is "is the
    /// microphone hearing anything", and it answers it at a glance.
    private var meter: some View {
        let level = session?.recorder.level ?? 0
        return HStack(spacing: 3) {
            ForEach(0..<28, id: \.self) { i in
                let threshold = Double(i) / 28
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(level > threshold ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(width: 5, height: 10 + CGFloat(i % 5) * 3)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .opacity(session?.isRecording == true ? 1 : 0.35)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            if session?.isRecording == true {
                Button {
                    Task { await session?.stop() }
                } label: {
                    Label("Stop & transcribe", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    Task { await session?.start(title: title.isEmpty ? nil : title, location: nil) }
                } label: {
                    Label("Start recording", systemImage: "mic.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!app.hasGeminiKey)
            }
        }
        .overlay(alignment: .bottom) {
            if !app.hasGeminiKey {
                Text("Add a Gemini API key in Settings first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .offset(y: 26)
            }
        }
    }

    // MARK: - Roster

    /// Named before anyone speaks, so the tagging pad is short and specific
    /// from the first second instead of a wall of everyone ever recorded.
    private var roster: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who's in this meeting?")
                .font(.headline)
            Text("Pick them now and tagging is one tap during the meeting. You can still add someone who turns up late.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !app.people.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(app.people) { person in
                        let isIn = session?.attendees.contains(person.name) ?? false
                        Button {
                            toggleAttendee(person.name)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isIn ? "checkmark.circle.fill" : "circle")
                                Text(person.name)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(isIn ? Color.accentColor : .secondary)
                    }
                }
            }

            HStack {
                TextField("Add someone new", text: $rosterName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRosterName() }
                Button("Add") { commitRosterName() }
                    .disabled(rosterName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let attendees = session?.attendees, !attendees.isEmpty {
                Text("In the room: \(attendees.joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private func toggleAttendee(_ name: String) {
        guard let session else { return }
        if let index = session.attendees.firstIndex(of: name) {
            session.attendees.remove(at: index)
        } else {
            session.attendees.append(name)
        }
    }

    private func commitRosterName() {
        let name = rosterName.trimmingCharacters(in: .whitespacesAndNewlines)
        rosterName = ""
        guard !name.isEmpty else { return }
        session?.addAttendee(name)
        Task { await app.addPerson(name) }
    }

    // MARK: - Tagging

    private var taggingPad: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who is speaking?")
                .font(.headline)
            Text("Tap a name once while they talk. Every turn in that voice gets their name — including the ones before and after the tap.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 8) {
                ForEach(taggableNames, id: \.self) { name in
                    Button(name) { session?.tag(name) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Button {
                    showingAddPerson = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if let tags = session?.tags, !tags.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Tagged so far")
                    .font(.subheadline.weight(.medium))
                ForEach(tags.reversed()) { tag in
                    HStack {
                        Text(tag.name)
                        Spacer()
                        Text(stamp(tag.atMs))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .alert("Add someone", isPresented: $showingAddPerson) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Add") {
                let name = newName
                newName = ""
                Task {
                    await app.addPerson(name)
                    // they are talking right now -- that is why you added them
                    session?.tag(name.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        } message: {
            Text("They'll be tagged as speaking right now.")
        }
    }

    // MARK: - Live preview

    /// Rough, on-device, unsaved -- but tappable. Each line carries the moment
    /// it was spoken, so pointing at one attributes that stretch of the
    /// meeting without having to catch the person mid-sentence.
    @ViewBuilder
    private var livePreview: some View {
        if let recorder = session?.recorder {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                    Text("Live preview")
                        .font(.headline)
                }

                switch recorder.live.availability {
                case .ready:
                    if recorder.live.isEmpty {
                        Text("Listening…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap a line to say who said it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        ForEach(recorder.live.chunks) { chunk in
                            chunkRow(chunk)
                        }

                        if !recorder.live.pending.isEmpty {
                            // Still being recognised, so its position is not
                            // settled yet; shown, but not offered for tagging.
                            Text(recorder.live.pending)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text("Rough and speakerless. The saved transcript is transcribed properly, with names, when you stop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .denied:
                    Text("Speech recognition permission was declined, so there's no live preview to tag. Use the names above instead — recording and the final transcript are unaffected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .unavailableOnDevice:
                    Text("This device can't transcribe on-device for your language, so the live preview is off — sending the audio to Apple to preview it isn't worth it. Use the names above; recording and the final transcript are unaffected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// One tappable line of preview. A menu rather than a sheet: naming should
    /// cost one tap and a pick, not a modal, in the middle of a conversation.
    private func chunkRow(_ chunk: LiveTranscriber.Chunk) -> some View {
        let tagged = session?.taggedName(from: chunk.startMs, to: chunk.endMs)

        return Menu {
            ForEach(taggableNames, id: \.self) { name in
                Button(name) { session?.tag(name, atMs: chunk.startMs) }
            }
            Divider()
            Button("Someone else…") {
                pendingChunkMs = chunk.startMs
                showingAddPerson = true
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let tagged {
                    Text(tagged)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(chunk.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                tagged == nil ? Color.clear : Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    /// The people worth showing a button for: whoever was named up front, or
    /// everyone known if the roster was skipped.
    private var taggableNames: [String] {
        let attendees = session?.attendees ?? []
        return attendees.isEmpty ? app.people.map(\.name) : attendees
    }

    private func stamp(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - Status

    @ViewBuilder
    private func status(_ phase: RecordingSession.Phase) -> some View {
        switch phase {
        case .idle, .recording:
            EmptyView()

        case .transcribing(let step):
            HStack(spacing: 10) {
                ProgressView()
                Text(step).foregroundStyle(.secondary)
            }

        case .finished(let meeting, let named, let unmatched):
            VStack(alignment: .leading, spacing: 8) {
                Label("Transcript saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text(named > 0
                     ? "^[\(named) speaker](inflect: true) named from your tags."
                     : "No tags matched a speaker — name them on the transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !unmatched.isEmpty {
                    Text("A voice after a 20-minute break couldn't be matched to an earlier one, so it appears as an extra speaker.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                NavigationLink("Open transcript") { TranscriptView(meetingId: meeting) }
                Button("New meeting") { session?.reset(); title = "" }
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label("Couldn't transcribe", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Try again") { Task { await session?.retry() } }
                        .buttonStyle(.borderedProminent)
                    Button("Discard") { session?.reset() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
