import Foundation

struct CaptionToken: Codable {
    let start: Double
    let end: Double
    var text: String
}

struct CaptionCue: Codable {
    let track: String
    let start: Double
    let end: Double
    let text: String
    var tokens: [CaptionToken]? = nil
}

// Keep the original journal intact; derive display/export segments as diarization arrives.
extension CaptionCue {
    func splitBySpeaker(turns: [SpeakerTurn]) -> [CaptionCue] {
        guard let tokens, !tokens.isEmpty, tokens.map(\.text).joined() == text else { return [self] }
        var previousEnd = start
        for token in tokens {
            guard token.start.isFinite, token.end.isFinite, token.start >= previousEnd,
                  token.end > token.start, token.end <= end else { return [self] }
            previousEnd = token.end
        }
        func identities(_ token: CaptionToken) -> Set<String> {
            Set(turns.filter { $0.track == track && min(token.end, $0.end) > max(token.start, $0.start) }.map(\.speakerID))
        }
        var groups: [[CaptionToken]] = []
        var previous: Set<String>?
        for token in tokens {
            let current = identities(token)
            if previous == current { groups[groups.count - 1].append(token) }
            else { groups.append([token]) }
            previous = current
        }
        return groups.map { group in
            CaptionCue(track: track, start: group.first!.start, end: group.last!.end,
                       text: group.map(\.text).joined(), tokens: group)
        }
    }
}

struct VoicePerson: Codable, Identifiable {
    var id: String
    var name: String
    var model: String
    var samples: [[Float]]
}
struct MeetingSpeaker: Codable, Identifiable {
    var id: String
    var track: String
    var number: Int
    var embedding: [Float]
    var personID: String?
    var name: String?
    var confirmed = false
    var speechSeconds: Double = 0
    var sampleSeconds: Double? = nil
    var label: String { "\(track == "microphone" ? "我方" : "会议方") · \(name ?? "说话人\(number)")" }
}
struct SpeakerTurn: Codable {
    var track: String
    var speakerID: String
    var start: Double
    var end: Double
}
struct SpeakerRecord: Codable {
    var model: String
    var speakers: [MeetingSpeaker] = []
}

enum VoiceIdentity {
    static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy({ $0.isFinite }) else { return nil }
        let length = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard length > 0.0001, length.isFinite else { return nil }
        return vector.map { $0 / length }
    }
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, let a = normalized(a), let b = normalized(b) else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
    // Deliberately conservative; only human-confirmed samples enter the persistent library.
    static func match(_ embedding: [Float], people: [VoicePerson], model: String, threshold: Float = 0.80, margin: Float = 0.08) -> VoicePerson? {
        let ranked = people.filter { $0.model == model }.map { person in
            (person, person.samples.map { similarity(embedding, $0) }.max() ?? -1)
        }.sorted { $0.1 > $1.1 }
        guard let first = ranked.first, first.1 >= threshold,
              ranked.count == 1 || first.1 - ranked[1].1 >= margin else { return nil }
        return first.0
    }
    static func label(track: String, start: Double, end: Double, turns: [SpeakerTurn], speakers: [MeetingSpeaker]) -> String {
        var durations: [String: Double] = [:]
        for turn in turns where turn.track == track {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 { durations[turn.speakerID, default: 0] += overlap }
        }
        let ranked = durations.sorted { $0.value > $1.value }
        let side = track == "microphone" ? "我方" : "会议方"
        guard let first = ranked.first, first.value >= min(0.3, (end - start) * 0.5),
              ranked.count == 1,
              let speaker = speakers.first(where: { $0.id == first.key }) else {
            return side + (ranked.count > 1 ? " · 多人/待确认" : " · 待识别")
        }
        return speaker.label
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// Bounded online centroids. Require repeated clean evidence before publishing a
// new identity; short/ambiguous observations never pull a centroid toward noise.
struct LiveSpeakerClusters {
    struct Cluster {
        var sum: [Float]
        var observations: Int
        var seconds: Double
        var lastSeen: Double
        var confirmed: Bool { observations >= 3 && seconds >= 6 }
    }
    private(set) var clusters: [Cluster] = []
    mutating func observe(_ embedding: [Float], seconds: Double, at time: Double = 0) -> (id: Int, confirmed: Bool, reset: Bool)? {
        guard seconds >= 1, let vector = VoiceIdentity.normalized(embedding) else { return nil }
        let ranked = clusters.indices.filter { clusters[$0].confirmed || time - clusters[$0].lastSeen <= 20 }
            .map { ($0, VoiceIdentity.similarity(vector, clusters[$0].sum)) }
            .sorted { $0.1 > $1.1 }
        let threshold: Float = seconds >= 1.5 ? 0.35 : 0.55
        if let best = ranked.first, best.1 >= threshold {
            guard ranked.count == 1 || best.1 - ranked[1].1 >= 0.08 else { return nil }
            if seconds >= 1.5 {
                clusters[best.0].lastSeen = time
                // Cap accumulated weight so adaptation and arithmetic stay bounded.
                if clusters[best.0].observations >= 100 {
                    clusters[best.0].sum = clusters[best.0].sum.map { $0 * 0.5 }
                    clusters[best.0].observations = 50
                }
                clusters[best.0].sum = zip(clusters[best.0].sum, vector).map(+)
                clusters[best.0].observations += 1
                clusters[best.0].seconds += seconds
            }
            return (best.0 + 1, clusters[best.0].confirmed, false)
        }
        guard seconds >= 2 else { return nil }
        let candidate = Cluster(sum: vector, observations: 1, seconds: seconds, lastSeen: time)
        if let expired = clusters.firstIndex(where: { !$0.confirmed && time - $0.lastSeen > 20 }) {
            clusters[expired] = candidate
            return (expired + 1, false, true)
        }
        guard clusters.count < 64 else { return nil }
        clusters.append(candidate)
        return (clusters.count, false, true)
    }
}

// Cross-meeting identity needs repeated independent windows, not one unusually
// similar (or dissimilar) longest utterance. Never writes automatic samples.
struct SpeakerMatchEvidence {
    private var candidateID: String?
    private var windows = 0
    private var seconds = 0.0
    mutating func observe(_ embedding: [Float], seconds duration: Double,
                          people: [VoicePerson], model: String) -> VoicePerson? {
        guard duration >= 1.5,
              let candidate = VoiceIdentity.match(embedding, people: people, model: model,
                                                  threshold: 0.55, margin: 0.12) else {
            candidateID = nil; windows = 0; seconds = 0
            return nil
        }
        if candidateID != candidate.id {
            candidateID = candidate.id; windows = 0; seconds = 0
        }
        windows += 1; seconds += duration
        return windows >= 3 && seconds >= 6 ? candidate : nil
    }
}
