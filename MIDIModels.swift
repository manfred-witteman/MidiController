import Foundation

struct RawMIDIMessage: Hashable {
    let status: UInt8
    let data1: UInt8
    let data2: UInt8

    var hexString: String {
        String(format: "%02X %02X %02X", status, data1, data2)
    }
}

enum MIDIProtocolKind: String {
    case raw
    case mackieControl
}

enum MackieTransportAction: String {
    case rewind
    case fastForward
    case stop
    case play
    case record

    var title: String {
        switch self {
        case .rewind: return "Rewind"
        case .fastForward: return "Forward"
        case .stop: return "Stop"
        case .play: return "Play"
        case .record: return "Record"
        }
    }
}

enum MIDITrigger: Hashable {
    case note(channel: Int, note: Int)
    case controlChange(channel: Int, controller: Int)
    case programChange(channel: Int, program: Int)
    case pitchBend(channel: Int)
    case mackieTransport(MackieTransportAction)
    case mackieVPot(index: Int)
    case mackieFader(index: Int)

    var label: String {
        switch self {
        case let .note(_, note):
            return midiNoteNameWithOctave(note)
        case let .controlChange(_, controller):
            return "\(controller)"
        case let .programChange(_, program):
            return "PC\(program)"
        case .pitchBend:
            return "Bend"
        case let .mackieTransport(action):
            return action.title
        case let .mackieVPot(index):
            return "Mackie V-Pot \(index)"
        case let .mackieFader(index):
            return "Mackie Fader \(index)"
        }
    }
}

enum MIDIEventKind: Hashable {
    case note(channel: Int, note: Int, velocity: Int, isOn: Bool)
    case controlChange(channel: Int, controller: Int, value: Int)
    case programChange(channel: Int, program: Int)
    case pitchBend(channel: Int, value: Int)
    case mackieTransport(MackieTransportAction)
    case mackieVPot(index: Int, value: Int)
    case mackieFader(index: Int, value: Int)
    case unknown(status: UInt8, data1: UInt8, data2: UInt8)

    var trigger: MIDITrigger? {
        switch self {
        case let .note(channel, note, _, _):
            return .note(channel: channel, note: note)
        case let .controlChange(channel, controller, _):
            return .controlChange(channel: channel, controller: controller)
        case let .programChange(channel, program):
            return .programChange(channel: channel, program: program)
        case let .pitchBend(channel, _):
            return .pitchBend(channel: channel)
        case let .mackieTransport(action):
            return .mackieTransport(action)
        case let .mackieVPot(index, _):
            return .mackieVPot(index: index)
        case let .mackieFader(index, _):
            return .mackieFader(index: index)
        case .unknown:
            return nil
        }
    }

    var iconName: String {
        switch self {
        case .note:
            return "pianokeys"
        case .controlChange:
            return "dial.medium"
        case .programChange:
            return "list.number"
        case .pitchBend, .mackieVPot:
            return "slider.vertical.3"
        case .mackieFader:
            return "slider.vertical.3"
        case .mackieTransport(.play):
            return "play.fill"
        case .mackieTransport(.stop):
            return "stop.fill"
        case .mackieTransport(.record):
            return "record.circle.fill"
        case .mackieTransport:
            return "arrow.left.arrow.right"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var title: String {
        switch self {
        case let .note(_, note, _, _):
            return midiNoteNameWithOctave(note)
        case let .controlChange(_, controller, _):
            return "\(controller)"
        case let .programChange(_, program):
            return "PC\(program)"
        case let .pitchBend(channel, _):
            return "\(channel + 1)"
        case let .mackieTransport(action):
            return action.title
        case let .mackieVPot(index, value):
            return "Mackie V-Pot \(index) = \(value)"
        case let .mackieFader(index, value):
            return "Mackie Fader \(index) = \(value)"
        case let .unknown(status, data1, data2):
            return String(format: "Unknown %02X %02X %02X", status, data1, data2)
        }
    }

    var logDetails: String {
        switch self {
        case let .controlChange(channel, controller, value):
            let twosComplement = relativeDeltaTwosComplement(value)
            let signedBit = relativeDeltaSignedBit(value)
            return "CC ch\(channel + 1) c\(controller) value=\(value) rel(tc)=\(twosComplement) rel(sb)=\(signedBit)"
        case let .mackieVPot(index, value):
            return "Mackie V-Pot \(index) value=\(value) rel=\(mackieRelativeDelta(value))"
        default:
            return title
        }
    }

    private func relativeDeltaTwosComplement(_ value: Int) -> Int {
        value <= 63 ? value : value - 128
    }

    private func relativeDeltaSignedBit(_ value: Int) -> Int {
        if value == 64 {
            return 0
        }
        if value > 64 {
            return value - 64
        }
        return -value
    }

    private func mackieRelativeDelta(_ value: Int) -> Int {
        if value <= 0x3F {
            return value
        }
        return -(value & 0x3F)
    }
}

private func midiNoteNameWithOctave(_ note: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let pitchClass = ((note % 12) + 12) % 12
    let octave = (note / 12) - 1
    return "\(names[pitchClass])\(octave)"
}

struct MIDIEvent: Hashable {
    let timestamp = Date()
    let sourceName: String
    let sourceID: Int32
    let protocolKind: MIDIProtocolKind
    let kind: MIDIEventKind
    let rawMessage: RawMIDIMessage

    var trigger: MIDITrigger? { kind.trigger }
    var title: String { kind.title }
    var iconName: String { kind.iconName }

    var logLine: String {
        let formatter = Self.logTimeFormatter
        let time = formatter.string(from: timestamp)
        let technical = rawMessage.technicalSummary
        let parsed = kind.logDetails
        return "[\(time)] [\(sourceName) #\(sourceID)] \(rawMessage.hexString) \(technical) parsed=\(parsed) mode=\(protocolKind.rawValue)"
    }

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private extension RawMIDIMessage {
    var technicalSummary: String {
        let type = messageTypeName
        if let channel = channel {
            return "type=\(type) ch=\(channel)"
        }
        return "type=\(type)"
    }

    var messageTypeName: String {
        let upper = status & 0xF0
        switch upper {
        case 0x80: return "NoteOff"
        case 0x90: return "NoteOn"
        case 0xA0: return "PolyAftertouch"
        case 0xB0: return "ControlChange"
        case 0xC0: return "ProgramChange"
        case 0xD0: return "ChannelAftertouch"
        case 0xE0: return "PitchBend"
        default: return "System"
        }
    }

    var channel: Int? {
        guard (0x80...0xEF).contains(status) else { return nil }
        return Int(status & 0x0F) + 1
    }
}
