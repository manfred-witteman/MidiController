import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var cells: [GridCellState] = Array(repeating: GridCellState(), count: 16)
    @Published var midiLog: [String] = []
    @Published var selectedCellIndex = 0
    @Published var isLearnEnabled = false
    @Published var learnPreviewEvent: MIDIEvent?
    @Published var obsRecordingActive = false
    @Published var obsInputMuteStates: [String: Bool] = [:]

    let defaultPluginID = "obs"
    let availablePlugins: [PluginDescriptor]

    private let pluginRegistry = PluginRegistry()
    private let midiService = MIDIService()
    private var pluginLogObserver: NSObjectProtocol?
    private var obsTargetsObserver: NSObjectProtocol?
    private var obsRecordingObserver: NSObjectProtocol?
    private var obsInputMuteObserver: NSObjectProtocol?
    private let persistedCellsKey = "AppViewModel.persistedCells.v1"
    private var recentDispatches: [DispatchDebounceKey: Date] = [:]
    private let instanceID = String(UUID().uuidString.prefix(8))

    init() {
        isLearnEnabled = false
        self.availablePlugins = pluginRegistry.plugins.map { PluginDescriptor(id: $0.id, name: $0.name) }
        appendToLog("[DEBUG] AppViewModel init id=\(instanceID)")
        loadPersistedCells()
        midiService.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
        pluginLogObserver = NotificationCenter.default.addObserver(
            forName: PluginLog.didEmit,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let line = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.appendToLog("[PLUGIN] \(line)")
            }
        }
        obsTargetsObserver = NotificationCenter.default.addObserver(
            forName: OBSTargetCatalog.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
        obsRecordingObserver = NotificationCenter.default.addObserver(
            forName: OBSState.recordingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let active = notification.object as? Bool else { return }
            self?.obsRecordingActive = active
        }
        obsInputMuteObserver = NotificationCenter.default.addObserver(
            forName: OBSState.inputMuteDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let userInfo = notification.userInfo,
                let inputName = userInfo["inputName"] as? String,
                let muted = userInfo["muted"] as? Bool
            else { return }
            self?.obsInputMuteStates[inputName] = muted
        }
    }

    deinit {
        print("[DEBUG] AppViewModel deinit id=\(instanceID)")
        if let observer = pluginLogObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = obsTargetsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = obsRecordingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = obsInputMuteObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var selectedCell: GridCellState? {
        cells[safe: selectedCellIndex]
    }

    func cellName(for index: Int) -> String {
        let row = index / 4
        let column = index % 4
        let letter = ["A", "B", "C", "D"][column]
        return "\(letter)\(row + 1)"
    }

    func mappingTitle(for index: Int) -> String {
        guard let mapping = cells[safe: index]?.mapping else {
            return ""
        }
        let pluginName = pluginRegistry.plugin(id: mapping.pluginID)?.name ?? mapping.pluginID
        let targetName = pluginRegistry.targetName(pluginID: mapping.pluginID, targetID: mapping.targetID) ?? mapping.targetID
        return "\(pluginName): \(targetName)"
    }

    var canRemoveLinkForSelectedCell: Bool {
        guard let cell = selectedCell else { return false }
        return cell.trigger != nil || cell.mapping != nil || cell.event != nil
    }

    func mappingTargetID(for index: Int) -> String? {
        cells[safe: index]?.mapping?.targetID
    }

    func obsMuteState(for targetID: String?) -> Bool? {
        guard let targetID else { return nil }
        guard targetID.hasPrefix("input.mute.toggle.") else { return nil }
        let encoded = String(targetID.dropFirst("input.mute.toggle.".count))
        guard let inputName = encoded.removingPercentEncoding else { return nil }
        return obsInputMuteStates[inputName]
    }

    func event(for index: Int) -> MIDIEvent? {
        cells[safe: index]?.event
    }

    func selectedTriggerTitle() -> String {
        guard let cell = selectedCell else { return "Geen selectie" }
        if let trigger = cell.trigger {
            if let sourceName = cell.triggerSourceName {
                return "\(trigger.label) (\(sourceName))"
            }
            return trigger.label
        }
        return "Nog geen MIDI trigger geleerd"
    }

    func pluginIDForSelectedCell() -> String {
        selectedCell?.mapping?.pluginID ?? defaultPluginID
    }

    func targetTitleForSelectedCell() -> String {
        guard
            let mapping = selectedCell?.mapping
        else {
            return "Selecteer target"
        }
        return pluginRegistry.targetName(pluginID: mapping.pluginID, targetID: mapping.targetID) ?? mapping.targetID
    }

    func targetGroupsForSelectedCell() -> [PluginTargetGroup] {
        let selectedPluginID = pluginIDForSelectedCell()
        return pluginRegistry.targetGroups(pluginID: selectedPluginID)
    }

    func refreshTargetsForSelectedCell() {
        let selectedPluginID = pluginIDForSelectedCell()
        pluginRegistry.refreshTargets(pluginID: selectedPluginID)
    }

    func setPluginForSelectedCell(id: String) {
        guard cells.indices.contains(selectedCellIndex) else { return }
        pluginRegistry.refreshTargets(pluginID: id)
        let targetID = pluginRegistry.firstTargetID(pluginID: id) ?? "unassigned"
        cells[selectedCellIndex].mapping = ControlMapping(pluginID: id, targetID: targetID)
        savePersistedCells()
    }

    func setTargetForSelectedCell(id: String) {
        guard cells.indices.contains(selectedCellIndex) else { return }
        let pluginID = cells[selectedCellIndex].mapping?.pluginID ?? defaultPluginID
        cells[selectedCellIndex].mapping = ControlMapping(pluginID: pluginID, targetID: id)
        savePersistedCells()
    }

    func removeLinkForSelectedCell() {
        guard cells.indices.contains(selectedCellIndex) else { return }
        cells[selectedCellIndex].trigger = nil
        cells[selectedCellIndex].triggerSourceID = nil
        cells[selectedCellIndex].triggerSourceName = nil
        cells[selectedCellIndex].mapping = nil
        cells[selectedCellIndex].event = nil
        savePersistedCells()
    }

    func clearMidiLog() {
        midiLog.removeAll()
    }

    func setLearnEnabled(_ enabled: Bool) {
        if isLearnEnabled == enabled { return }
        isLearnEnabled = enabled
        appendToLog("[DEBUG] Learn toggled -> \(enabled ? "ON" : "OFF")")
        if !enabled {
            learnPreviewEvent = nil
        }
    }

    func sendOBSDebugToggle() {
        let raw = RawMIDIMessage(status: 0x90, data1: 0, data2: 0)
        let event = MIDIEvent(
            sourceName: "Internal Debug",
            sourceID: -1,
            protocolKind: .raw,
            kind: .unknown(status: raw.status, data1: raw.data1, data2: raw.data2),
            rawMessage: raw
        )
        appendToLog("[DEBUG] Sending OBS toggle test")
        pluginRegistry.plugin(id: "obs")?.handle(event: event, targetID: "recording.toggle")
    }

    private func handle(event: MIDIEvent) {
        appendToLog(event.logLine)
        appendToLog("[DEBUG] State -> vm=\(instanceID) learn=\(isLearnEnabled) selectedCell=\(selectedCellIndex)")

        guard cells.indices.contains(selectedCellIndex) else {
            return
        }

        if isLearnEnabled {
            appendToLog("[DEBUG] Learn input -> selectedCell=\(selectedCellIndex) event=\(event.title)")
            learnPreviewEvent = event
            guard let trigger = event.trigger else {
                appendToLog("[DEBUG] Learn input ignored: no trigger parsed")
                return
            }

            let previousTrigger = cells[selectedCellIndex].trigger
            let previousSourceID = cells[selectedCellIndex].triggerSourceID
            let previousSourceName = cells[selectedCellIndex].triggerSourceName
            let previousMapping = cells[selectedCellIndex].mapping

            cells[selectedCellIndex].trigger = trigger
            cells[selectedCellIndex].triggerSourceID = event.sourceID
            cells[selectedCellIndex].triggerSourceName = event.sourceName
            cells[selectedCellIndex].event = event
            appendToLog("[DEBUG] Learn preview applied -> cell=\(selectedCellIndex) trigger=\(trigger.label)")
            applyAnimation(to: selectedCellIndex, event: event)

            if cells[selectedCellIndex].mapping == nil {
                let targetID = preferredDefaultTargetID(for: event)
                cells[selectedCellIndex].mapping = ControlMapping(pluginID: defaultPluginID, targetID: targetID)
            }

            if previousTrigger != cells[selectedCellIndex].trigger
                || previousSourceID != cells[selectedCellIndex].triggerSourceID
                || previousSourceName != cells[selectedCellIndex].triggerSourceName
                || previousMapping != cells[selectedCellIndex].mapping {
                savePersistedCells()
            }
            return
        }

        if learnPreviewEvent != nil {
            learnPreviewEvent = nil
        }

        if let trigger = event.trigger {
            for index in cells.indices {
                guard cells[index].trigger == trigger else { continue }
                if !isSourceMatch(cell: cells[index], event: event) {
                    continue
                }
                cells[index].event = event
                applyAnimation(to: index, event: event)
                if let mapping = cells[index].mapping {
                    if shouldDispatch(event: event, forCellAt: index) {
                        pluginRegistry.plugin(id: mapping.pluginID)?.handle(event: event, targetID: mapping.targetID)
                    }
                }
            }
        }
    }

    private func appendToLog(_ line: String) {
        midiLog.insert(line, at: 0)
        if midiLog.count > 200 {
            midiLog.removeLast(midiLog.count - 200)
        }
        print(line)
    }

    private func applyAnimation(to index: Int, event: MIDIEvent) {
        guard cells.indices.contains(index) else { return }
        cells[index].lastActivityAt = Date()
        if !isLearnEnabled {
            cells[index].hitFeedbackNonce += 1
        }
        switch event.kind {
        case .note, .programChange:
            cells[index].controllerMode = .unknown
            cells[index].absoluteFill = 0
            cells[index].relativeDirection = 0
            cells[index].pulseNonce += 1
        case .mackieTransport:
            cells[index].controllerMode = .unknown
            cells[index].absoluteFill = 0
            cells[index].relativeDirection = 0
            cells[index].transportNonce += 1
        case let .controlChange(_, _, value):
            applyControlAnimation(to: &cells[index], value: value)
        case let .mackieVPot(_, value):
            let delta = mackieRelativeDelta(value)
            cells[index].controllerMode = .relative
            cells[index].relativeDirection = delta == 0 ? 0 : (delta > 0 ? 1 : -1)
            advanceRelativePhase(for: &cells[index], delta: delta)
        case let .mackieFader(_, value):
            cells[index].controllerMode = .absolute
            cells[index].absoluteFill = max(0, min(1, Double(value) / 16383.0))
        case let .pitchBend(_, value):
            cells[index].controllerMode = .absolute
            cells[index].absoluteFill = max(0, min(1, Double(value) / 16383.0))
        case .unknown:
            break
        }
    }

    private func applyControlAnimation(to cell: inout GridCellState, value: Int) {
        if looksLikeRelativeValue(value) {
            cell.relativeEvidence += 1
        } else {
            cell.absoluteEvidence += 1
        }

        if cell.relativeEvidence >= 3 && cell.relativeEvidence > cell.absoluteEvidence {
            cell.controllerMode = .relative
        } else if cell.absoluteEvidence >= 3 && cell.absoluteEvidence >= cell.relativeEvidence {
            cell.controllerMode = .absolute
        }

        let delta = relativeSignedBitDelta(value)
        switch cell.controllerMode {
        case .relative:
            cell.relativeDirection = delta == 0 ? 0 : (delta > 0 ? 1 : -1)
            advanceRelativePhase(for: &cell, delta: delta)
        case .absolute:
            cell.absoluteFill = max(0, min(1, Double(value) / 127.0))
        case .unknown:
            if looksLikeRelativeValue(value) {
                cell.relativeDirection = delta == 0 ? 0 : (delta > 0 ? 1 : -1)
                advanceRelativePhase(for: &cell, delta: delta)
            } else {
                cell.absoluteFill = max(0, min(1, Double(value) / 127.0))
            }
        }
    }

    private func looksLikeRelativeValue(_ value: Int) -> Bool {
        if value == 64 { return true }
        if (1...8).contains(value) || (120...127).contains(value) { return true }
        if (56...72).contains(value) { return true }
        return false
    }

    private func relativeSignedBitDelta(_ value: Int) -> Int {
        if value == 64 { return 0 }
        if value > 64 { return value - 64 }
        return -value
    }

    private func mackieRelativeDelta(_ value: Int) -> Int {
        if value <= 0x3F {
            return value
        }
        return -(value & 0x3F)
    }

    private func advanceRelativePhase(for cell: inout GridCellState, delta: Int) {
        guard delta != 0 else { return }
        let magnitude = min(max(abs(delta), 1), 8)
        let step = Double(magnitude) / 10.0
        cell.relativePhase += step
    }

    private func isSourceMatch(cell: GridCellState, event: MIDIEvent) -> Bool {
        if let storedSourceID = cell.triggerSourceID, storedSourceID == event.sourceID {
            return true
        }
        if let storedSourceName = cell.triggerSourceName,
           storedSourceName.caseInsensitiveCompare(event.sourceName) == .orderedSame {
            return true
        }
        return cell.triggerSourceID == nil && cell.triggerSourceName == nil
    }

    private func preferredDefaultTargetID(for event: MIDIEvent) -> String {
        if case .mackieTransport(.record) = event.kind {
            return "recording.toggle"
        }
        return pluginRegistry.firstTargetID(pluginID: defaultPluginID) ?? "unassigned"
    }

    private func shouldDispatch(event: MIDIEvent, forCellAt index: Int) -> Bool {
        guard let trigger = event.trigger else { return true }
        guard isDiscreteTrigger(event.kind) else { return true }

        let key = DispatchDebounceKey(cellIndex: index, sourceID: event.sourceID, trigger: trigger)
        let now = event.timestamp
        if let previous = recentDispatches[key], now.timeIntervalSince(previous) < 0.18 {
            return false
        }
        recentDispatches[key] = now

        // Keep this cache bounded.
        if recentDispatches.count > 512 {
            let cutoff = now.addingTimeInterval(-10)
            recentDispatches = recentDispatches.filter { $0.value > cutoff }
        }
        return true
    }

    private func isDiscreteTrigger(_ kind: MIDIEventKind) -> Bool {
        switch kind {
        case .note, .programChange, .mackieTransport:
            return true
        case .controlChange, .pitchBend, .mackieVPot, .mackieFader, .unknown:
            return false
        }
    }

    private func loadPersistedCells() {
        guard
            let data = UserDefaults.standard.data(forKey: persistedCellsKey),
            let persisted = try? JSONDecoder().decode([PersistedGridCell].self, from: data)
        else {
            return
        }

        var restored = Array(repeating: GridCellState(), count: 16)
        for (index, entry) in persisted.prefix(restored.count).enumerated() {
            restored[index].trigger = entry.trigger?.toRuntime()
            restored[index].triggerSourceID = entry.triggerSourceID
            restored[index].triggerSourceName = entry.triggerSourceName
            restored[index].mapping = entry.mapping
        }
        cells = restored
    }

    private func savePersistedCells() {
        let persisted = cells.map { cell in
            PersistedGridCell(
                trigger: cell.trigger.map(PersistedTrigger.fromRuntime),
                triggerSourceID: cell.triggerSourceID,
                triggerSourceName: cell.triggerSourceName,
                mapping: cell.mapping
            )
        }

        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: persistedCellsKey)
    }
}

private struct PersistedGridCell: Codable {
    let trigger: PersistedTrigger?
    let triggerSourceID: Int32?
    let triggerSourceName: String?
    let mapping: ControlMapping?
}

private struct PersistedTrigger: Codable {
    let kind: String
    let channel: Int?
    let note: Int?
    let controller: Int?
    let program: Int?
    let action: String?
    let index: Int?

    static func fromRuntime(_ trigger: MIDITrigger) -> PersistedTrigger {
        switch trigger {
        case let .note(channel, note):
            return PersistedTrigger(
                kind: "note",
                channel: channel,
                note: note,
                controller: nil,
                program: nil,
                action: nil,
                index: nil
            )
        case let .controlChange(channel, controller):
            return PersistedTrigger(
                kind: "controlChange",
                channel: channel,
                note: nil,
                controller: controller,
                program: nil,
                action: nil,
                index: nil
            )
        case let .programChange(channel, program):
            return PersistedTrigger(
                kind: "programChange",
                channel: channel,
                note: nil,
                controller: nil,
                program: program,
                action: nil,
                index: nil
            )
        case let .pitchBend(channel):
            return PersistedTrigger(
                kind: "pitchBend",
                channel: channel,
                note: nil,
                controller: nil,
                program: nil,
                action: nil,
                index: nil
            )
        case let .mackieTransport(action):
            return PersistedTrigger(
                kind: "mackieTransport",
                channel: nil,
                note: nil,
                controller: nil,
                program: nil,
                action: action.rawValue,
                index: nil
            )
        case let .mackieVPot(index):
            return PersistedTrigger(
                kind: "mackieVPot",
                channel: nil,
                note: nil,
                controller: nil,
                program: nil,
                action: nil,
                index: index
            )
        case let .mackieFader(index):
            return PersistedTrigger(
                kind: "mackieFader",
                channel: nil,
                note: nil,
                controller: nil,
                program: nil,
                action: nil,
                index: index
            )
        }
    }

    func toRuntime() -> MIDITrigger? {
        switch kind {
        case "note":
            guard let channel, let note else { return nil }
            return .note(channel: channel, note: note)
        case "controlChange":
            guard let channel, let controller else { return nil }
            return .controlChange(channel: channel, controller: controller)
        case "programChange":
            guard let channel, let program else { return nil }
            return .programChange(channel: channel, program: program)
        case "pitchBend":
            guard let channel else { return nil }
            return .pitchBend(channel: channel)
        case "mackieTransport":
            guard let action, let transportAction = MackieTransportAction(rawValue: action) else { return nil }
            return .mackieTransport(transportAction)
        case "mackieVPot":
            guard let index else { return nil }
            return .mackieVPot(index: index)
        case "mackieFader":
            guard let index else { return nil }
            return .mackieFader(index: index)
        default:
            return nil
        }
    }
}

struct PluginDescriptor: Identifiable {
    let id: String
    let name: String
}

struct GridCellState: Hashable {
    var trigger: MIDITrigger?
    var triggerSourceID: Int32?
    var triggerSourceName: String?
    var event: MIDIEvent?
    var mapping: ControlMapping?
    var pulseNonce = 0
    var absoluteFill = 0.0
    var relativeDirection = 0
    var relativePhase = 0.0
    var controllerMode: ControllerMode = .unknown
    var relativeEvidence = 0
    var absoluteEvidence = 0
    var lastActivityAt: Date?
    var transportNonce = 0
    var hitFeedbackNonce = 0
}

enum ControllerMode: Hashable {
    case unknown
    case absolute
    case relative
}

private struct DispatchDebounceKey: Hashable {
    let cellIndex: Int
    let sourceID: Int32
    let trigger: MIDITrigger
}
