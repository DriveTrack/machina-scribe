import SwiftUI

/// The in-meeting screen. Everything here is sized to be hit without looking:
/// during a real conversation you glance down for half a second at most.
struct RecordView: View {
    @Environment(AppState.self) private var app

    @State private var title = ""
    @State private var newName = ""
    @State private var showingAddPerson = false

    private var session: RecordingSession? { app.session }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                meter
                controls
                if session?.isRecording == true { taggingPad }
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
                ForEach(app.people) { person in
                    Button(person.name) { session?.tag(person.name) }
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
