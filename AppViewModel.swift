import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var cells: [GridCellState] = Array(repeating: GridCellState(), count: 16)
    @Published var midiLog: [String] = []
    @Published var selectedCellIndex = 0
    @Published var isLearnEnabled = true

    let defaultPluginID = "obs"
    let availablePlugins: [PluginDescriptor]

    private let pluginRegistry = PluginRegistry()
    private let midiService = MIDIService()

    init() {
        self.availablePlugins = pluginRegistry.plugins.map { PluginDescriptor(id: $0.id, name: $0.name) }
        midiService.onEvent = { [weak self] event in
            self?.handle(event: event)
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
            return "Geen mapping"
        }
        let pluginName = pluginRegistry.plugin(id: mapping.pluginID)?.name ?? mapping.pluginID
        let targetName = pluginRegistry.targetName(pluginID: mapping.pluginID, targetID: mapping.targetID) ?? mapping.targetID
        return "\(pluginName): \(targetName)"
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
        return pluginRegistry.plugin(id: selectedPluginID)?.targetGroups ?? []
    }

    func setPluginForSelectedCell(id: String) {
        guard cells.indices.contains(selectedCellIndex) else { return }
        let targetID = pluginRegistry.firstTargetID(pluginID: id) ?? "unassigned"
        cells[selectedCellIndex].mapping = ControlMapping(pluginID: id, targetID: targetID)
    }

    func setTargetForSelectedCell(id: String) {
        guard cells.indices.contains(selectedCellIndex) else { return }
        let pluginID = cells[selectedCellIndex].mapping?.pluginID ?? defaultPluginID
        cells[selectedCellIndex].mapping = ControlMapping(pluginID: pluginID, targetID: id)
    }

    func clearMidiLog() {
        midiLog.removeAll()
    }

    private func handle(event: MIDIEvent) {
        appendToLog(event.logLine)

        var selectedWasMatched = false
        if let trigger = event.trigger {
            for index in cells.indices {
                guard cells[index].trigger == trigger else { continue }
                if !isSourceMatch(cell: cells[index], event: event) {
                    continue
                }
                cells[index].event = event
                applyAnimation(to: index, event: event)
                if let mapping = cells[index].mapping {
                    pluginRegistry.plugin(id: mapping.pluginID)?.handle(event: event, targetID: mapping.targetID)
                }
                if index == selectedCellIndex {
                    selectedWasMatched = true
                }
            }
        }

        guard cells.indices.contains(selectedCellIndex) else {
            return
        }

        if !isLearnEnabled { return }

        guard let trigger = event.trigger else {
            return
        }

        cells[selectedCellIndex].trigger = trigger
        cells[selectedCellIndex].triggerSourceID = event.sourceID
        cells[selectedCellIndex].triggerSourceName = event.sourceName
        cells[selectedCellIndex].event = event
        if !selectedWasMatched {
            applyAnimation(to: selectedCellIndex, event: event)
        }

        if cells[selectedCellIndex].mapping == nil {
            let targetID = pluginRegistry.firstTargetID(pluginID: defaultPluginID) ?? "unassigned"
            cells[selectedCellIndex].mapping = ControlMapping(pluginID: defaultPluginID, targetID: targetID)
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
