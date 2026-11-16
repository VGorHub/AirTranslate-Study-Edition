import Foundation
import Testing
@testable import AirTranslate

struct StudyBackendTests {
    @Test
    @MainActor
    func revisedPartialBecomesOneFinalAndAcceptsOnlyMatchingTranslation() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let backend = StudyBackend(databaseURL: url)
        let initial = await backend.status()
        let cursor = try #require(StudyCursor(value: initial.cursor))
        let capture = StudyCapture(backend: backend)
        let line = UUID()

        capture.start(engine: "apple", model: "apple-system", sourceLanguage: "en-US", targetLanguage: "ru-RU")
        capture.record("The class str", final: false, providerID: "audio-1", audioRange: 1.2...2.2)
        capture.record("The class starts", final: false, providerID: "audio-1", audioRange: 1.2...2.6)
        capture.record("The class starts.", final: true, providerID: "audio-1", language: "en-US",
                       audioRange: 1.2...2.8, captionID: line)
        capture.record("The class starts.", final: true, providerID: "audio-1", language: "en-US",
                       audioRange: 1.2...2.8)
        capture.translate("Прежний перевод", matching: "The class starts", language: "ru-RU", captionID: line)
        capture.translate("Занятие начинается.", matching: "The class starts.", language: "ru-RU", captionID: line)
        capture.record("The class starts.", final: true, providerID: "audio-2", audioRange: 6.0...7.3)
        capture.record("An unfinished sentence", final: false)
        capture.record("", final: true)
        capture.setState(.completed)
        await capture.close()

        let history = try await backend.sessions(offset: 0, limit: 1)
        let session = try #require(history.sessions.first?.session)
        #expect(session.state == .completed)
        let page = try #require(try await backend.segments(id: session.id, after: 0, limit: 10))
        #expect(page.partials.isEmpty)
        #expect(page.segments.map(\.text) == ["The class starts.", "The class starts."])
        let first = try #require(page.segments.first)
        #expect(first.revision == 3)
        #expect(first.startMilliseconds == 1200)
        #expect(first.endMilliseconds == 2800)
        #expect(first.translation == "Занятие начинается.")
        #expect(first.translationLanguage == "ru-RU")
        #expect(page.segments.last?.id != first.id)

        let (_, stream) = try #require(await backend.subscribe(after: cursor))
        await backend.disconnectSubscribers()
        var frames: [StudyEventFrame] = []
        for await element in stream {
            if let element { frames.append(element) }
        }
        #expect(frames.map(\.kind) == [
            .status, .partial, .partial, .final, .translation, .final, .partial, .retract, .status
        ])
        try #require(frames.count == 9)
        #expect(frames[1..<5].allSatisfy { $0.event.segment?.id == first.id })
        #expect(frames[6].event.segment?.id == frames[7].event.segmentID)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func openAIConfirmedDeltasPersistBeforeStopAndDoNotDuplicateTerminalAliases() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let backend = StudyBackend(databaseURL: url)
        let cursor = try #require(StudyCursor(value: await backend.status().cursor))
        let (_, stream) = try #require(await backend.subscribe(after: cursor))
        let capture = StudyCapture(backend: backend)
        capture.start(engine: "openAI", model: "gpt-realtime-translate", sourceLanguage: nil, targetLanguage: "ru-RU")
        capture.appendConfirmed("A cont", channel: .source, language: nil, audioMilliseconds: 200)
        capture.appendConfirmed("inuous sentence.", channel: .source, language: nil, audioMilliseconds: 1_400)
        capture.recordOpenAIRealtimeSnapshot("A continuous sentence.", final: true, providerID: nil,
                                             channel: .source, language: nil)
        capture.appendConfirmed("Перевод", channel: .translation, language: "ru-RU", audioMilliseconds: nil)
        capture.setState(.paused)
        var sessionID: UUID?
        for await frame in stream {
            if let session = frame?.event.session, session.state == .paused {
                sessionID = session.id
                break
            }
        }
        await backend.disconnectSubscribers()
        let id = try #require(sessionID)
        let page = try #require(try await backend.segments(id: id, after: 0, limit: 10))
        #expect(page.segments.map(\.text) == ["A continuous sentence.", "Перевод"])
        #expect(page.segments.first?.startMilliseconds == 200)
        #expect(page.segments.first?.endMilliseconds == 1_400)
        #expect(page.segments.last?.channel == .translation)
        await capture.close()
    }

    @Test
    @MainActor
    func retainsConfirmedSegmentsWhenDatabaseTemporarilyLocked() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let backend = StudyBackend(databaseURL: url)
        let session = sessionFixture()
        let final = segmentFixture(session: session, position: 1, isFinal: true)
        do {
            let owner = try StudyDatabase(url: url)
            await backend.apply(.status(session))
            await backend.apply(.segment(session, final, .final))
            #expect(await backend.status().storageAvailable == false)
            #expect(try owner.segments(sessionID: session.id, after: 0, limit: 10).isEmpty)
        }
        await backend.flush(force: true)
        let page = try #require(try await backend.segments(id: session.id, after: 0, limit: 10))
        #expect(page.segments == [final])
        #expect(await backend.status().storageAvailable)
    }

    @Test
    func recoveryPreservesConfirmedTextAndDoesNotStorePartials() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let session = sessionFixture()
        let final = segmentFixture(session: session, position: 1, isFinal: true)
        let partial = segmentFixture(session: session, position: 2, isFinal: false)
        try await recordThenLoseProcess(url: url, session: session, final: final, partial: partial)

        let restored = StudyBackend(databaseURL: url)
        let page = try #require(try await restored.segments(id: session.id, after: 0, limit: 10))
        #expect(page.session.session.state == .interrupted)
        #expect(page.session.durationMilliseconds == 10_800_000)
        #expect(page.segments == [final])
        #expect(page.partials.isEmpty)
        #expect(await restored.status().activeSession == nil)
    }

    @Test
    func paginatesLongSessionAndResyncsExpiredEventCursor() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(url) }
        let session = sessionFixture()
        let segments = (1...2_400).map { segmentFixture(session: session, position: $0, isFinal: true) }
        do {
            let database = try StudyDatabase(url: url)
            try database.save(sessions: [session], segments: segments)
        }
        let backend = StudyBackend(databaseURL: url)
        let oldCursor = try #require(StudyCursor(value: await backend.status().cursor))
        var position = 0
        var read: [UUID] = []
        repeat {
            let page = try #require(try await backend.segments(id: session.id, after: position, limit: 333))
            read.append(contentsOf: page.segments.map(\.id))
            position = page.nextPosition ?? 0
        } while position != 0
        #expect(read == segments.map(\.id))

        let nextSession = sessionFixture()
        await backend.apply(.status(nextSession))
        for index in 1...270 {
            await backend.apply(.segment(nextSession, segmentFixture(session: nextSession, position: index,
                                                                    isFinal: false), .partial))
        }
        let (_, stream) = try #require(await backend.subscribe(after: oldCursor))
        await backend.disconnectSubscribers()
        var iterator = stream.makeAsyncIterator()
        let frame = await iterator.next() ?? nil
        #expect(frame?.kind == .resync)
    }

    private func recordThenLoseProcess(url: URL, session: StudySession, final: StudySegment,
                                       partial: StudySegment) async throws {
        let backend = StudyBackend(databaseURL: url)
        await backend.apply(.status(session))
        await backend.apply(.segment(session, final, .final))
        await backend.apply(.segment(session, partial, .partial))
        let page = try #require(try await backend.segments(id: session.id, after: 0, limit: 10))
        #expect(page.segments == [final])
        #expect(page.partials == [partial])
        #expect(page.session.session.state == .recording)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "sessions.sqlite3")
    }

    private func removeDatabase(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func sessionFixture() -> StudySession {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return StudySession(id: UUID(), startedAt: startedAt, sourceLanguage: "en-US", targetLanguage: "ru-RU",
                            engine: "apple", model: "apple-system",
                            state: .recording, updatedAt: startedAt.addingTimeInterval(10_800))
    }

    private func segmentFixture(session: StudySession, position: Int, isFinal: Bool) -> StudySegment {
        StudySegment(id: UUID(), sessionID: session.id, position: position, channel: .source,
                     startMilliseconds: Int64(position) * 4_500, endMilliseconds: nil, timing: .receipt,
                     language: "en-US", revision: 1, isFinal: isFinal, text: "Sample phrase \(position).")
    }
}
