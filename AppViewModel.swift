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
    private let serverStartedAt = Date()
    private var autosaveCancellable: AnyCancellable?
    private var remoteBridge: DesktopBonjourBridge?
    private var remotePadActions: [Int: RemotePadAction] = [:]

    init() {
        isLearnEnabled = false
        self.availablePlugins = pluginRegistry.plugins.map { PluginDescriptor(id: $0.id, name: $0.name) }
        appendToLog("[DEBUG] AppViewModel init id=\(instanceID)")
        loadPersistedCells()
        autosaveCancellable = $cells
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.savePersistedCells()
            }
        remoteBridge = DesktopBonjourBridge(
            snapshotProvider: { [weak self] in
                self?.buildRemoteSnapshot() ?? RemoteSnapshot(appName: "MIDI Controller", generatedAt: Date(), serverInstanceID: nil, serverStartedAt: nil, sceneName: nil, scenes: nil, currentSceneIndex: nil, recordingActive: false, pads: [])
            },
            tapHandler: { [weak self] index in
                self?.dispatchRemoteTap(on: index)
            },
            valueHandler: { [weak self] index, normalized in
                self?.dispatchRemoteValue(on: index, normalized: normalized)
            },
            systemHandler: { [weak self] action in
                self?.dispatchRemoteSystemAction(action)
            }
        )
        remoteBridge?.start()
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
        remoteBridge?.stop()
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

    func selectCell(_ index: Int) {
        guard cells.indices.contains(index) else { return }
        if selectedCellIndex == index { return }
        selectedCellIndex = index
        if isLearnEnabled {
            learnPreviewEvent = nil
        }
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

    private func buildRemoteSnapshot() -> RemoteSnapshot {
        remotePadActions.removeAll()
        let controls = OBSPlugin.remoteSceneControls()
        let sceneState = OBSPlugin.remoteSceneListState()
        let pads: [RemotePadModel] = controls.map { control in
            let style: RemoteTriggerStyle = control.normalizedValue != nil ? .controlAbsolute : .note
            if let sceneItemID = control.sceneItemID {
                remotePadActions[control.id] = .sceneControl(sceneName: control.sceneName, sceneItemID: sceneItemID)
            } else if let inputName = control.inputName {
                remotePadActions[control.id] = .inputControl(inputName: inputName)
            }
            return RemotePadModel(
                id: control.id,
                title: control.sourceName,
                triggerLabel: "",
                triggerStyle: style,
                targetTitle: control.sourceName,
                hasMapping: true,
                statusText: control.statusText,
                normalizedValue: control.normalizedValue
            )
        }
        return RemoteSnapshot(
            appName: "MIDI Controller",
            generatedAt: Date(),
            serverInstanceID: instanceID,
            serverStartedAt: serverStartedAt,
            sceneName: OBSPlugin.currentSceneName(),
            scenes: sceneState.scenes,
            currentSceneIndex: sceneState.currentIndex,
            recordingActive: obsRecordingActive,
            pads: pads
        )
    }

    private func remoteTriggerStyle(for trigger: MIDITrigger?) -> RemoteTriggerStyle {
        guard let trigger else { return .unknown }
        switch trigger {
        case .note:
            return .note
        case .controlChange:
            return .controlAbsolute
        case .programChange:
            return .program
        case .pitchBend, .mackieFader:
            return .pitch
        case .mackieTransport:
            return .transport
        case .mackieVPot:
            return .controlRelative
        }
    }

    private func dispatchRemoteTap(on index: Int) {
        if let action = remotePadActions[index] {
            switch action {
            case let .sceneControl(sceneName, sceneItemID):
                OBSPlugin.toggleSceneItem(sceneName: sceneName, sceneItemID: sceneItemID)
            case let .inputControl(inputName):
                OBSPlugin.toggleInputMuteDirect(inputName: inputName)
            }
            return
        }
        guard cells.indices.contains(index) else { return }
        guard let trigger = cells[index].trigger else { return }
        let event = syntheticEvent(for: trigger, sourceName: "iOS Remote", sourceID: -1000, normalized: nil)
        cells[index].event = event
        applyAnimation(to: index, event: event)
        if let mapping = cells[index].mapping {
            pluginRegistry.plugin(id: mapping.pluginID)?.handle(event: event, targetID: mapping.targetID)
        }
    }

    private func dispatchRemoteValue(on index: Int, normalized: Double) {
        if let action = remotePadActions[index] {
            switch action {
            case let .sceneControl(sceneName, sceneItemID):
                OBSPlugin.setSceneItemLevel(sceneName: sceneName, sceneItemID: sceneItemID, normalized: normalized)
            case let .inputControl(inputName):
                OBSPlugin.setInputVolumeDirect(inputName: inputName, normalized: normalized)
            }
            return
        }
        guard cells.indices.contains(index) else { return }
        guard let trigger = cells[index].trigger else { return }
        let event = syntheticEvent(for: trigger, sourceName: "iOS Remote", sourceID: -1000, normalized: normalized)
        cells[index].event = event
        applyAnimation(to: index, event: event)
        if let mapping = cells[index].mapping {
            pluginRegistry.plugin(id: mapping.pluginID)?.handle(event: event, targetID: mapping.targetID)
        }
    }

    private func dispatchRemoteSystemAction(_ action: RemoteSystemAction) {
        switch action {
        case .previousScene:
            OBSPlugin.goToPreviousScene()
        case .nextScene:
            OBSPlugin.goToNextScene()
        case .toggleRecording:
            OBSPlugin.toggleRecording()
        case .refresh:
            OBSPlugin.refreshCatalog()
        }
    }

    private func remoteStatus(for index: Int, cell: GridCellState) -> (text: String, normalized: Double?) {
        if let targetID = mappingTargetID(for: index),
           let muteState = obsMuteState(for: targetID) {
            return (muteState ? "Uit" : "Aan", muteState ? 0.0 : 1.0)
        }
        guard let event = cell.event else {
            return ("Tap", nil)
        }
        switch event.kind {
        case let .controlChange(_, _, value):
            let norm = max(0.0, min(1.0, Double(value) / 127.0))
            return ("\(Int(norm * 100))%", norm)
        case let .pitchBend(_, value):
            let norm = max(0.0, min(1.0, Double(value) / 16383.0))
            return ("\(Int(norm * 100))%", norm)
        case let .mackieFader(_, value):
            let norm = max(0.0, min(1.0, Double(value) / 16383.0))
            return ("\(Int(norm * 100))%", norm)
        case let .note(_, _, velocity, _):
            let norm = max(0.0, min(1.0, Double(velocity) / 127.0))
            return ("\(Int(norm * 100))%", norm)
        default:
            return ("Aan", 1.0)
        }
    }

    private enum RemotePadAction {
        case sceneControl(sceneName: String, sceneItemID: Int)
        case inputControl(inputName: String)
    }

    private func syntheticEvent(for trigger: MIDITrigger, sourceName: String, sourceID: Int32, normalized: Double?) -> MIDIEvent {
        switch trigger {
        case let .note(channel, note):
            let velocity = Int((normalized ?? 1.0) * 127.0)
            return MIDIEvent(
                sourceName: sourceName,
                sourceID: sourceID,
                protocolKind: .raw,
                kind: .note(channel: channel, note: note, velocity: max(1, velocity), isOn: true),
                rawMessage: RawMIDIMessage(status: UInt8(0x90 | (channel & 0x0F)), data1: UInt8(note & 0x7F), data2: UInt8(max(1, velocity) & 0x7F))
            )
        case let .controlChange(channel, controller):
            let value = Int((normalized ?? 0.5) * 127.0)
            return MIDIEvent(
                sourceName: sourceName,
                sourceID: sourceID,
                protocolKind: .raw,
                kind: .controlChange(channel: channel, controller: controller, value: max(0, min(127, value))),
                rawMessage: RawMIDIMessage(status: UInt8(0xB0 | (channel & 0x0F)), data1: UInt8(controller & 0x7F), data2: UInt8(max(0, min(127, value))))
            )
        case let .programChange(channel, program):
            return MIDIEvent(
                sourceName: sourceName,
                sourceID: sourceID,
                protocolKind: .raw,
                kind: .programChange(channel: channel, program: program),
                rawMessage: RawMIDIMessage(status: UInt8(0xC0 | (channel & 0x0F)), data1: UInt8(program & 0x7F), data2: 0)
            )
        case let .pitchBend(channel):
            let bend = Int((normalized ?? 0.5) * 16383.0)
            let lsb = bend & 0x7F
            let msb = (bend >> 7) & 0x7F
            return MIDIEvent(
                sourceName: sourceName,
                sourceID: sourceID,
                protocolKind: .raw,
                kind: .pitchBend(channel: channel, value: bend),
                rawMessage: RawMIDIMessage(status: UInt8(0xE0 | (channel & 0x0F)), data1: UInt8(lsb), data2: UInt8(msb))
            )
        case let .mackieTransport(action):
            let note: Int
            switch action {
            case .rewind: note = 91
            case .fastForward: note = 92
            case .stop: note = 93
            case .play: note = 94
            case .record: note = 95
            }
            return MIDIEvent(
                sourceName: sourceName,
                sourceID: sourceID,
                protocolKind: .mackieControl,
                kind: .mackieTransport(action),
                rawMessage: RawMIDIMessage(status: 0x90, data1: UInt8(note), data2: 0x7F)
            )
        case let .mackieVPot(index):
            let value = normalized.map { $0 >= 0.5 ? 1 : 65 } ?? 1
            return MIDIEvent(
                sourceName: sourceName,
                sourceID: sourceID,
                protocolKind: .mackieControl,
                kind: .mackieVPot(index: index, value: value),
                rawMessage: RawMIDIMessage(status: 0xB0, data1: UInt8((index + 15) & 0x7F), data2: UInt8(value & 0x7F))
            )
        case let .mackieFader(index):
            let fader = Int((normalized ?? 0.5) * 16383.0)
            let channel = max(0, min(7, index - 1))
            let lsb = fader & 0x7F
            let msb = (fader >> 7) & 0x7F
            return MIDIEvent(
                sourceName: sourceName,
                sourceID: sourceID,
                protocolKind: .mackieControl,
                kind: .mackieFader(index: index, value: fader),
                rawMessage: RawMIDIMessage(status: UInt8(0xE0 | channel), data1: UInt8(lsb), data2: UInt8(msb))
            )
        }
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
            var matchedIndices: [Int] = []
            for index in cells.indices {
                guard cells[index].trigger == trigger else { continue }
                if !isSourceMatch(cell: cells[index], event: event) {
                    continue
                }
                matchedIndices.append(index)
                cells[index].event = event
                applyAnimation(to: index, event: event)
                if let mapping = cells[index].mapping {
                    if shouldDispatch(event: event, forCellAt: index) {
                        pluginRegistry.plugin(id: mapping.pluginID)?.handle(event: event, targetID: mapping.targetID)
                    }
                }
            }
            appendToLog("[DEBUG] Runtime match -> trigger=\(trigger.label) cells=\(matchedIndices)")
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
        var removedLegacySceneMappings = false
        for index in restored.indices {
            guard let mapping = restored[index].mapping else { continue }
            if mapping.pluginID == "obs",
               mapping.targetID.hasPrefix("scene.program."),
               !mapping.targetID.hasPrefix("scene.program.uuid.") {
                restored[index].mapping = nil
                removedLegacySceneMappings = true
            }
        }
        cells = restored
        if removedLegacySceneMappings {
            appendToLog("[DEBUG] Legacy OBS scene-name mappings removed; reselect scenes using UUID-based targets.")
            savePersistedCells()
        }
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
