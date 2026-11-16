import Foundation

struct StudyCursor: Equatable, Sendable {
    let streamID: UUID
    let sequence: Int64

    var value: String { "\(streamID.uuidString):\(sequence)" }

    init(streamID: UUID, sequence: Int64) {
        self.streamID = streamID
        self.sequence = sequence
    }

    init?(value: String) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let streamID = UUID(uuidString: String(parts[0])),
              let sequence = Int64(parts[1]), sequence >= 0 else { return nil }
        self.init(streamID: streamID, sequence: sequence)
    }
}

struct StudySession: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case recording, paused, reconnecting, finishing, completed, interrupted

        var isActive: Bool { self != .completed && self != .interrupted }
    }

    let id: UUID
    let startedAt: Date
    let sourceLanguage: String?
    let targetLanguage: String?
    let engine: String
    let model: String
    var state: State
    var updatedAt: Date

    var durationMilliseconds: Int64 {
        Int64(max(0, updatedAt.timeIntervalSince(startedAt) * 1_000))
    }

    var endedAt: Date? { state.isActive ? nil : updatedAt }
}

struct StudySegment: Codable, Equatable, Sendable {
    enum Channel: String, Codable, Hashable, Sendable { case source, translation }
    enum Timing: String, Codable, Sendable { case audio, receipt }

    let id: UUID
    let sessionID: UUID
    let position: Int
    let channel: Channel
    let startMilliseconds: Int64
    let endMilliseconds: Int64?
    let timing: Timing
    let language: String?
    let revision: Int
    let isFinal: Bool
    let text: String
    var translation: String?
    var translationLanguage: String?
}

struct StudyEvent: Encodable, Sendable {
    enum Kind: String, Sendable { case status, partial, final, translation, retract, resync }

    let cursor: String
    let sessionID: UUID?
    let session: StudySession?
    let segment: StudySegment?
    let segmentID: UUID?
    let storageAvailable: Bool
}

struct StudyEventFrame: Sendable {
    let kind: StudyEvent.Kind
    let event: StudyEvent
}

enum StudyMutation: Sendable {
    case status(StudySession)
    case segment(StudySession, StudySegment, StudyEvent.Kind)
    case retract(StudySession, UUID)
}

struct StudySessionPage: Encodable, Sendable {
    let sessions: [StudySessionSummary]
    let nextOffset: Int?
}

struct StudySessionSummary: Encodable, Sendable {
    let session: StudySession
    var durationMilliseconds: Int64
    var endedAt: Date?

    init(_ session: StudySession) {
        self.session = session
        self.durationMilliseconds = session.durationMilliseconds
        self.endedAt = session.endedAt
    }
}

struct StudySegmentPage: Encodable, Sendable {
    let session: StudySessionSummary
    let segments: [StudySegment]
    let partials: [StudySegment]
    let nextPosition: Int?
    let cursor: String
}

struct StudyStatus: Encodable, Sendable {
    let activeSession: StudySessionSummary?
    let storageAvailable: Bool
    let cursor: String
}
