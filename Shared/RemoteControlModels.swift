import Foundation

enum RemoteTriggerStyle: String, Codable {
    case note
    case controlAbsolute
    case controlRelative
    case transport
    case pitch
    case program
    case unknown
}

struct RemotePadModel: Codable, Identifiable {
    let id: Int
    let title: String
    let triggerLabel: String
    let triggerStyle: RemoteTriggerStyle
    let targetTitle: String
    let hasMapping: Bool
    let statusText: String
    let normalizedValue: Double?
}

struct RemoteSnapshot: Codable {
    let appName: String
    let generatedAt: Date
    let serverInstanceID: String?
    let serverStartedAt: Date?
    let sceneName: String?
    let scenes: [String]?
    let currentSceneIndex: Int?
    let recordingActive: Bool
    let pads: [RemotePadModel]
}

enum RemoteSystemAction: String, Codable {
    case previousScene
    case nextScene
    case toggleRecording
    case refresh
}

enum RemoteCommand: Codable {
    case snapshot
    case tap(pad: Int)
    case setValue(pad: Int, normalized: Double)
    case system(action: RemoteSystemAction)

    enum CodingKeys: String, CodingKey {
        case type
        case pad
        case normalized
        case action
    }

    enum Kind: String, Codable {
        case snapshot
        case tap
        case setValue
        case system
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .snapshot:
            self = .snapshot
        case .tap:
            let pad = try container.decode(Int.self, forKey: .pad)
            self = .tap(pad: pad)
        case .setValue:
            let pad = try container.decode(Int.self, forKey: .pad)
            let normalized = try container.decode(Double.self, forKey: .normalized)
            self = .setValue(pad: pad, normalized: normalized)
        case .system:
            let action = try container.decode(RemoteSystemAction.self, forKey: .action)
            self = .system(action: action)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot:
            try container.encode(Kind.snapshot, forKey: .type)
        case let .tap(pad):
            try container.encode(Kind.tap, forKey: .type)
            try container.encode(pad, forKey: .pad)
        case let .setValue(pad, normalized):
            try container.encode(Kind.setValue, forKey: .type)
            try container.encode(pad, forKey: .pad)
            try container.encode(normalized, forKey: .normalized)
        case let .system(action):
            try container.encode(Kind.system, forKey: .type)
            try container.encode(action, forKey: .action)
        }
    }
}

enum RemoteResponse: Codable {
    case snapshot(RemoteSnapshot)
    case ack
    case error(String)

    enum CodingKeys: String, CodingKey {
        case type
        case snapshot
        case message
    }

    enum Kind: String, Codable {
        case snapshot
        case ack
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .snapshot:
            let snapshot = try container.decode(RemoteSnapshot.self, forKey: .snapshot)
            self = .snapshot(snapshot)
        case .ack:
            self = .ack
        case .error:
            self = .error(try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .snapshot(snapshot):
            try container.encode(Kind.snapshot, forKey: .type)
            try container.encode(snapshot, forKey: .snapshot)
        case .ack:
            try container.encode(Kind.ack, forKey: .type)
        case let .error(message):
            try container.encode(Kind.error, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
