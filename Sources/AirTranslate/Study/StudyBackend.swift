import Foundation
import OSLog

actor StudyBackend {
    private static let replayLimit = 256
    private static let subscriberLimit = 8
    private let databaseURL: URL
    private let logger = Logger(subsystem: "dev.appcaster.AirTranslate", category: "StudyStorage")
    private let streamID = UUID()
    private var sequence: Int64 = 0
    private var database: StudyDatabase?
    private var nextRetry: ContinuousClock.Instant?
    private var pendingSessions: [UUID: StudySession] = [:]
    private var pendingSegments: [UUID: StudySegment] = [:]
    private var activeSession: StudySession?
    private var partials: [UUID: StudySegment] = [:]
    private var replay: [StudyEventFrame] = []
    private var subscribers: [UUID: AsyncStream<StudyEventFrame?>.Continuation] = [:]

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func apply(_ mutation: StudyMutation) {
        switch mutation {
        case .status(let session):
            if activeSession?.id != session.id || !session.state.isActive {
                partials.removeAll()
            }
            activeSession = session.state.isActive ? session : nil
            pendingSessions[session.id] = session
            flush()
            publish(.status, session: session)
        case .segment(let session, let segment, let kind):
            guard activeSession?.id == session.id else { return }
            activeSession = session
            if segment.isFinal {
                partials.removeValue(forKey: segment.id)
                pendingSessions[session.id] = session
                pendingSegments[segment.id] = segment
                flush()
            } else {
                partials[segment.id] = segment
            }
            publish(kind, session: session, segment: segment)
        case .retract(let session, let id):
            guard activeSession?.id == session.id, partials.removeValue(forKey: id) != nil else { return }
            publish(.retract, session: session, segmentID: id)
        }
    }

    func flush(force: Bool = false) {
        if !force, let nextRetry, nextRetry > .now { return }
        let recovering = nextRetry != nil
        do {
            if database == nil {
                database = try StudyDatabase(url: databaseURL)
            }
            if !pendingSessions.isEmpty || !pendingSegments.isEmpty {
                try database?.save(sessions: Array(pendingSessions.values), segments: Array(pendingSegments.values))
                pendingSessions.removeAll()
                pendingSegments.removeAll()
            }
            nextRetry = nil
            if recovering { publish(.status, session: activeSession) }
        } catch {
            if !recovering {
                logger.error("Study session storage failed: \(String(describing: error), privacy: .private)")
            }
            nextRetry = .now.advanced(by: .seconds(2))
        }
    }

    func tick() {
        if nextRetry != nil { flush() }
        for (id, continuation) in subscribers {
            deliver(nil, to: continuation, id: id)
        }
    }

    func status() -> StudyStatus {
        flush()
        return StudyStatus(activeSession: activeSession.map(StudySessionSummary.init),
                           storageAvailable: storageAvailable, cursor: cursor.value)
    }

    func sessions(offset: Int, limit: Int) throws -> StudySessionPage {
        let rows = try readableDatabase().sessions(offset: offset, limit: limit + 1)
        return StudySessionPage(
            sessions: rows.prefix(limit).map { StudySessionSummary(activeSession?.id == $0.id ? activeSession ?? $0 : $0) },
            nextOffset: rows.count > limit ? offset + limit : nil
        )
    }

    func segments(id: UUID, after: Int, limit: Int) throws -> StudySegmentPage? {
        let database = try readableDatabase()
        guard let session = try database.session(id: id) else { return nil }
        let rows = try database.segments(sessionID: id, after: after, limit: limit + 1)
        let page = Array(rows.prefix(limit))
        let current = activeSession.flatMap { $0.id == id ? $0 : nil }
        return StudySegmentPage(
            session: StudySessionSummary(current ?? session),
            segments: page,
            partials: current == nil ? [] : partials.values.sorted { $0.position < $1.position },
            nextPosition: rows.count > limit ? page.last?.position : nil,
            cursor: cursor.value
        )
    }

    func subscribe(after requested: StudyCursor?) -> (UUID, AsyncStream<StudyEventFrame?>)? {
        guard subscribers.count < Self.subscriberLimit else { return nil }
        let id = UUID()
        let (stream, continuation) = AsyncStream<StudyEventFrame?>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.replayLimit + 1)
        )
        subscribers[id] = continuation
        if let requested, requested.streamID == streamID, requested.sequence <= sequence,
           requested.sequence >= sequence - Int64(replay.count) {
            let replayStart = replay.count - Int(sequence - requested.sequence)
            for frame in replay.dropFirst(replayStart) { continuation.yield(frame) }
        } else {
            continuation.yield(frame(.resync, session: activeSession))
        }
        return (id, stream)
    }

    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    func disconnectSubscribers() {
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private var cursor: StudyCursor { StudyCursor(streamID: streamID, sequence: sequence) }
    private var storageAvailable: Bool { database != nil && nextRetry == nil }

    private func readableDatabase() throws -> StudyDatabase {
        flush()
        guard storageAvailable, let database else { throw StudyDatabase.Failure.schema }
        return database
    }

    private func publish(_ kind: StudyEvent.Kind, session: StudySession?,
                         segment: StudySegment? = nil, segmentID: UUID? = nil) {
        sequence += 1
        let frame = frame(kind, session: session, segment: segment, segmentID: segmentID)
        replay.append(frame)
        if replay.count > Self.replayLimit { replay.removeFirst() }
        for (id, continuation) in subscribers {
            deliver(frame, to: continuation, id: id)
        }
    }

    private func deliver(_ frame: StudyEventFrame?, to continuation: AsyncStream<StudyEventFrame?>.Continuation,
                         id: UUID) {
        switch continuation.yield(frame) {
        case .enqueued: break
        case .dropped, .terminated: unsubscribe(id)
        @unknown default: unsubscribe(id)
        }
    }

    private func frame(_ kind: StudyEvent.Kind, session: StudySession?,
                       segment: StudySegment? = nil, segmentID: UUID? = nil) -> StudyEventFrame {
        StudyEventFrame(kind: kind, event: StudyEvent(
            cursor: cursor.value, sessionID: session?.id, session: kind == .status ? session : nil,
            segment: segment, segmentID: segmentID, storageAvailable: storageAvailable
        ))
    }
}
