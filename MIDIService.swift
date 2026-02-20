import CoreMIDI
import Foundation

final class MIDIService {
    var onEvent: ((MIDIEvent) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedSourceIDs = Set<MIDIUniqueID>()

    init() {
        setup()
    }

    deinit {
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    private func setup() {
        MIDIClientCreateWithBlock("MidiController.Client" as CFString, &client) { [weak self] _ in
            self?.refreshConnections()
        }

        MIDIInputPortCreateWithBlock(client, "MidiController.Input" as CFString, &inputPort) { [weak self] packetList, srcConnRefCon in
            guard let self else { return }

            let source = srcConnRefCon.map { MIDIEndpointRef(UInt32(UInt(bitPattern: $0))) } ?? 0
            let sourceName = self.endpointName(for: source)
            let sourceID = self.uniqueID(for: source)

            var packet = packetList.pointee.packet
            for _ in 0..<packetList.pointee.numPackets {
                let bytes = withUnsafeBytes(of: packet.data) { raw in
                    Array(raw.prefix(Int(packet.length)))
                }

                let events = MIDIMessageParser.parse(bytes: bytes, sourceName: sourceName, sourceID: sourceID)
                if !events.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        for event in events {
                            self.onEvent?(event)
                        }
                    }
                }
                packet = MIDIPacketNext(&packet).pointee
            }
        }

        refreshConnections()
    }

    private func refreshConnections() {
        var currentSourceIDs = Set<MIDIUniqueID>()

        let sourceCount = MIDIGetNumberOfSources()
        guard sourceCount > 0 else {
            connectedSourceIDs.removeAll()
            return
        }

        for index in 0..<sourceCount {
            let source = MIDIGetSource(index)
            let sourceID = uniqueID(for: source)
            currentSourceIDs.insert(sourceID)

            if connectedSourceIDs.contains(sourceID) {
                continue
            }

            let sourceContext = UnsafeMutableRawPointer(bitPattern: Int(source))
            MIDIPortConnectSource(inputPort, source, sourceContext)
            connectedSourceIDs.insert(sourceID)
        }

        connectedSourceIDs = connectedSourceIDs.intersection(currentSourceIDs)
    }

    private func uniqueID(for object: MIDIObjectRef) -> MIDIUniqueID {
        var value: Int32 = 0
        MIDIObjectGetIntegerProperty(object, kMIDIPropertyUniqueID, &value)
        return value
    }

    private func endpointName(for endpoint: MIDIEndpointRef) -> String {
        guard endpoint != 0 else { return "Unknown Source" }
        var unmanagedName: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName)
        if status == noErr, let name = unmanagedName?.takeRetainedValue() {
            return name as String
        }
        return "MIDI Source \(endpoint)"
    }
}

enum MIDIMessageParser {
    static func parse(bytes: [UInt8], sourceName: String, sourceID: Int32) -> [MIDIEvent] {
        var events: [MIDIEvent] = []
        var index = 0
        let looksLikeMackie = isLikelyMackieSource(sourceName)

        while index < bytes.count {
            let status = bytes[index]

            if status < 0x80 {
                index += 1
                continue
            }

            let messageType = status & 0xF0
            let channel = Int(status & 0x0F)
            let data1 = index + 1 < bytes.count ? bytes[index + 1] : 0
            let data2 = index + 2 < bytes.count ? bytes[index + 2] : 0

            let kind: MIDIEventKind
            switch messageType {
            case 0x80, 0x90:
                let velocity = Int(data2)
                let isOn = messageType == 0x90 && velocity > 0
                if !isOn {
                    index += 3
                    continue
                }
                if let action = transportAction(note: Int(data1), velocity: velocity, isOn: isOn, channel: channel, sourceName: sourceName, looksLikeMackie: looksLikeMackie) {
                    kind = .mackieTransport(action)
                } else {
                    kind = .note(channel: channel, note: Int(data1), velocity: velocity, isOn: isOn)
                }
                index += 3
            case 0xB0:
                if looksLikeMackie, (16...23).contains(Int(data1)) {
                    kind = .mackieVPot(index: Int(data1) - 15, value: Int(data2))
                } else {
                    kind = .controlChange(channel: channel, controller: Int(data1), value: Int(data2))
                }
                index += 3
            case 0xC0:
                kind = .programChange(channel: channel, program: Int(data1))
                index += 2
            case 0xE0:
                let bend = Int(data1) | (Int(data2) << 7)
                if looksLikeMackie, channel < 8 {
                    kind = .mackieFader(index: channel + 1, value: bend)
                } else {
                    kind = .pitchBend(channel: channel, value: bend)
                }
                index += 3
            default:
                kind = .unknown(status: status, data1: data1, data2: data2)
                index += 1
            }

            let protocolKind: MIDIProtocolKind
            switch kind {
            case .mackieTransport, .mackieVPot, .mackieFader:
                protocolKind = .mackieControl
            default:
                protocolKind = .raw
            }
            events.append(
                MIDIEvent(
                    sourceName: sourceName,
                    sourceID: sourceID,
                    protocolKind: protocolKind,
                    kind: kind,
                    rawMessage: RawMIDIMessage(status: status, data1: data1, data2: data2)
                )
            )
        }

        return events
    }

    private static func isLikelyMackieSource(_ sourceName: String) -> Bool {
        let normalized = sourceName.lowercased()
        return normalized.contains("mackie") || normalized.contains("control universal")
    }

    private static func mackieTransportAction(note: Int, velocity: Int, isOn: Bool, channel: Int) -> MackieTransportAction? {
        guard channel == 0, isOn, velocity > 0 else { return nil }
        switch note {
        case 91: return .rewind
        case 92: return .fastForward
        case 93: return .stop
        case 94: return .play
        case 95: return .record
        default: return nil
        }
    }

    private static func arturiaDAWTransportAction(note: Int, velocity: Int, isOn: Bool, sourceName: String) -> MackieTransportAction? {
        guard isOn, velocity > 0 else { return nil }
        let normalized = sourceName.lowercased()
        guard normalized.contains("arturia"), normalized.contains("daw") else { return nil }
        switch note {
        case 95: return .stop
        case 94: return .play
        case 93: return .record
        default: return nil
        }
    }

    private static func transportAction(note: Int, velocity: Int, isOn: Bool, channel: Int, sourceName: String, looksLikeMackie: Bool) -> MackieTransportAction? {
        if looksLikeMackie, let action = mackieTransportAction(note: note, velocity: velocity, isOn: isOn, channel: channel) {
            return action
        }
        return arturiaDAWTransportAction(note: note, velocity: velocity, isOn: isOn, sourceName: sourceName)
    }
}
