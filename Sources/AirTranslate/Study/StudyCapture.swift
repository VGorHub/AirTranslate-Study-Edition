import Foundation

/// Adapts accepted provider results on MainActor and sends ordered updates to the database actor.
@MainActor
final class StudyCapture {
    private struct Key: Hashable {
        let channel: StudySegment.Channel
        let providerID: String
    }

    private struct Entry {
        var segment: StudySegment
        var rawText: String
    }

    private struct ConfirmedBlock {
        let id = UUID().uuidString
        var text = ""
        var language: String?
        var firstAudioTime: Double?
        var lastAudioTime: Double?
    }

    private let backend: StudyBackend
    private let updates: AsyncStream<StudyMutation>.Continuation
    private let worker: Task<Void, Never>
    private var session: StudySession?
    private var startedAtUptime: TimeInterval = 0
    private var position = 0
    private var entries: [Key: Entry] = [:]
    private var openTurns: [StudySegment.Channel: String] = [:]
    private var captions: [UUID: Key] = [:]
    private var confirmedBlocks: [StudySegment.Channel: ConfirmedBlock] = [:]
    private var confirmedFlush: Task<Void, Never>?

    init(backend: StudyBackend) {
        self.backend = backend
        let (stream, updates) = AsyncStream<StudyMutation>.makeStream()
        self.updates = updates
        worker = Task {
            for await update in stream { await backend.apply(update) }
        }
    }

    deinit {
        confirmedFlush?.cancel()
        updates.finish()
    }

    func start(engine: String, model: String, sourceLanguage: String?, targetLanguage: String?) {
        guard session == nil else { return }
        let now = Date()
        let session = StudySession(id: UUID(), startedAt: now, sourceLanguage: sourceLanguage,
                                   targetLanguage: targetLanguage, engine: engine, model: model,
                                   state: .recording, updatedAt: now)
        self.session = session
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        updates.yield(.status(session))
    }

    func setState(_ state: StudySession.State) {
        guard let prior = session, prior.state != state else { return }
        if !state.isActive || state == .paused { flushConfirmed() }
        guard let current = self.session else { return }
        var session = touch(current)
        session.state = state
        self.session = session
        updates.yield(.status(session))
        if !state.isActive {
            self.session = nil
            entries.removeAll()
            openTurns.removeAll()
            captions.removeAll()
            confirmedBlocks.removeAll()
            position = 0
        }
    }

    func close() async {
        setState(.interrupted)
        updates.finish()
        await worker.value
        await backend.flush(force: true)
    }

    func retractPartials() {
        guard let session else { return }
        for (key, entry) in entries where !entry.segment.isFinal {
            entries.removeValue(forKey: key)
            updates.yield(.retract(session, entry.segment.id))
        }
        openTurns.removeAll()
    }

    func finishTurn(channel: StudySegment.Channel, language: String?) {
        guard let id = openTurns[channel], let entry = entries[Key(channel: channel, providerID: id)] else { return }
        record(entry.rawText, final: true, channel: channel, language: language)
    }

    func appendConfirmed(_ text: String, channel: StudySegment.Channel, language: String?, audioMilliseconds: Int64?) {
        guard session != nil, !text.isEmpty else { return }
        if confirmedBlocks[channel] == nil {
            record("", final: true, channel: channel)
        }
        var block = confirmedBlocks[channel] ?? ConfirmedBlock()
        block.text += text
        block.language = language
        if let audioMilliseconds, audioMilliseconds >= 0 {
            let seconds = Double(audioMilliseconds) / 1_000
            block.firstAudioTime = block.firstAudioTime ?? seconds
            block.lastAudioTime = max(block.lastAudioTime ?? seconds, seconds)
        }
        confirmedBlocks[channel] = block
        let end = block.text.last { !$0.isWhitespace }
        if block.text.utf8.count >= 600 || end.map({ ".!?。！？".contains($0) }) == true {
            saveConfirmedBlock(channel, rotate: true)
        } else if confirmedFlush == nil {
            confirmedFlush = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                self?.flushConfirmed()
            }
        }
    }

    func recordOpenAIRealtimeSnapshot(_ text: String, final: Bool, providerID: String?,
                                     channel: StudySegment.Channel, language: String?) {
        // An append-only stream has already committed its text, including when a legacy terminal alias arrives.
        guard confirmedBlocks[channel] == nil else { return }
        record(text, final: final, providerID: providerID, channel: channel, language: language)
    }

    private func flushConfirmed() {
        confirmedFlush?.cancel()
        confirmedFlush = nil
        for channel in [StudySegment.Channel.source, .translation] {
            saveConfirmedBlock(channel, rotate: false)
        }
    }

    private func saveConfirmedBlock(_ channel: StudySegment.Channel, rotate: Bool) {
        guard let block = confirmedBlocks[channel], !block.text.isEmpty else { return }
        let range = block.firstAudioTime.flatMap { first in block.lastAudioTime.map { first...$0 } }
        record(block.text, final: true, providerID: block.id, channel: channel, language: block.language, audioRange: range)
        if rotate { confirmedBlocks[channel] = ConfirmedBlock() }
    }

    func record(_ text: String, final: Bool, providerID: String? = nil,
                channel: StudySegment.Channel = .source, language: String? = nil,
                audioRange: ClosedRange<Double>? = nil, delta: Bool = false,
                captionID: UUID? = nil) {
        guard let current = session else { return }
        let id = providerID ?? openTurns[channel] ?? UUID().uuidString
        let key = Key(channel: channel, providerID: id)
        let previous = entries[key]
        if previous?.segment.isFinal == true && !final { return }
        let rawText = delta ? (previous?.rawText ?? "") + text : text
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = final ? trimmed : String(trimmed.suffix(4_000))
        if text.isEmpty {
            if final, let previous, !previous.segment.isFinal {
                entries.removeValue(forKey: key)
                updates.yield(.retract(current, previous.segment.id))
                if openTurns[channel] == id { openTurns.removeValue(forKey: channel) }
            } else if delta, let previous {
                entries[key] = Entry(segment: previous.segment, rawText: rawText)
            }
            return
        }
        if let captionID { captions[captionID] = key }
        if providerID == nil {
            openTurns[channel] = final ? nil : id
        }
        let language = language ?? previous?.segment.language
        if let previous, previous.segment.text == text, previous.segment.isFinal == final,
           previous.segment.language == language,
           audioRange == nil || previous.segment.endMilliseconds == audioRange.map({ milliseconds($0.upperBound) }) {
            entries[key] = Entry(segment: previous.segment, rawText: rawText)
            return
        }
        if previous == nil { position += 1 }
        let moment = touch(current)
        let start = audioRange.map { milliseconds($0.lowerBound) }
        let end = audioRange.map { milliseconds($0.upperBound) }
        let segment = StudySegment(
            id: previous?.segment.id ?? UUID(), sessionID: current.id,
            position: previous?.segment.position ?? position, channel: channel,
            startMilliseconds: start ?? previous?.segment.startMilliseconds ?? moment.durationMilliseconds,
            endMilliseconds: end ?? previous?.segment.endMilliseconds,
            timing: start == nil ? previous?.segment.timing ?? .receipt : .audio,
            language: language, revision: (previous?.segment.revision ?? 0) + 1,
            isFinal: final, text: text
        )
        entries[key] = Entry(segment: segment, rawText: rawText)
        session = moment
        updates.yield(.segment(moment, segment, final ? .final : .partial))
    }

    func translate(_ text: String, matching sourceText: String, language: String,
                   captionID: UUID, providerID: String? = nil) {
        guard let current = session else { return }
        let key = providerID.map { Key(channel: .source, providerID: $0) } ?? captions[captionID]
        guard let key, var entry = entries[key], entry.segment.isFinal,
              entry.segment.text == sourceText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, entry.segment.translation != text || entry.segment.translationLanguage != language else { return }
        entry.segment.translation = text
        entry.segment.translationLanguage = language
        entries[key] = entry
        let moment = touch(current)
        session = moment
        updates.yield(.segment(moment, entry.segment, .translation))
    }

    private func touch(_ session: StudySession) -> StudySession {
        var session = session
        session.updatedAt = session.startedAt.addingTimeInterval(ProcessInfo.processInfo.systemUptime - startedAtUptime)
        return session
    }

    private func milliseconds(_ seconds: Double) -> Int64 {
        Int64((max(0, seconds) * 1_000).rounded())
    }
}
