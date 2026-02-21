//
//  ContentView.swift
//  MidiController
//
//  Created by Manfred on 20/02/2026.
//

import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showOBSSettings = false
    @State private var showDeleteLinkConfirmation = false
    @State private var obsHost = OBSConnectionSettings.default.host
    @State private var obsPort = String(OBSConnectionSettings.default.port)
    @State private var obsPassword = OBSConnectionSettings.default.password
    #if canImport(AppKit)
    @State private var localDeleteKeyMonitor: Any?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("MIDI Controller")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("OBS") {
                    loadOBSSettings()
                    showOBSSettings = true
                }
                Button("OBS Test") {
                    viewModel.sendOBSDebugToggle()
                }
                Button(viewModel.isLearnEnabled ? "Learn ON" : "Learn OFF") {
                    viewModel.setLearnEnabled(!viewModel.isLearnEnabled)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isLearnEnabled ? .green : .gray)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(0..<16, id: \.self) { index in
                    EventCellView(
                        cellState: viewModel.cells[index],
                        mappingTitle: viewModel.mappingTitle(for: index),
                        mappingTargetID: viewModel.mappingTargetID(for: index),
                        previewEvent: (viewModel.isLearnEnabled && index == viewModel.selectedCellIndex) ? viewModel.learnPreviewEvent : nil,
                        obsRecordingActive: viewModel.obsRecordingActive,
                        obsMuteActive: viewModel.obsMuteState(for: viewModel.mappingTargetID(for: index)),
                        isSelected: index == viewModel.selectedCellIndex,
                        tileColor: tileColor(for: index),
                        isLearnEnabled: viewModel.isLearnEnabled
                    )
                    .onTapGesture {
                        viewModel.selectedCellIndex = index
                    }
                }
            }

            Divider()

            MappingEditorView(viewModel: viewModel)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Inkomende MIDI log")
                        .font(.headline)
                    Spacer()
                    Button("Clear") {
                        viewModel.clearMidiLog()
                    }
                    .disabled(viewModel.midiLog.isEmpty)
                }

                ScrollView {
                    Text(viewModel.midiLog.joined(separator: "\n"))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.08))
                )
            }

            Text("Mackie Control: transport-knoppen, V-Pots en faders worden herkend.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .sheet(isPresented: $showOBSSettings) {
            OBSSettingsSheet(
                host: $obsHost,
                port: $obsPort,
                password: $obsPassword,
                onCancel: {
                    showOBSSettings = false
                },
                onSave: {
                    saveOBSSettings()
                    showOBSSettings = false
                }
            )
        }
        .onDeleteCommand {
            guard viewModel.isLearnEnabled, viewModel.canRemoveLinkForSelectedCell else { return }
            showDeleteLinkConfirmation = true
        }
        .confirmationDialog(
            "Koppeling verwijderen?",
            isPresented: $showDeleteLinkConfirmation,
            titleVisibility: .visible
        ) {
            Button("Verwijder koppeling", role: .destructive) {
                viewModel.removeLinkForSelectedCell()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.isLearnEnabled || !viewModel.canRemoveLinkForSelectedCell)
            Button("Annuleren", role: .cancel) {}
        } message: {
            Text("De MIDI-trigger en target van de geselecteerde tegel worden verwijderd.")
        }
        #if canImport(AppKit)
        .onAppear {
            installDeleteKeyMonitorIfNeeded()
        }
        .onDisappear {
            removeDeleteKeyMonitor()
        }
        #endif
    }

    private func tileColor(for index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.92, green: 0.34, blue: 0.31),
            Color(red: 0.95, green: 0.56, blue: 0.24),
            Color(red: 0.94, green: 0.76, blue: 0.25),
            Color(red: 0.66, green: 0.82, blue: 0.29),
            Color(red: 0.28, green: 0.74, blue: 0.38),
            Color(red: 0.26, green: 0.78, blue: 0.63),
            Color(red: 0.22, green: 0.67, blue: 0.86),
            Color(red: 0.30, green: 0.52, blue: 0.91),
            Color(red: 0.49, green: 0.43, blue: 0.91),
            Color(red: 0.70, green: 0.35, blue: 0.90),
            Color(red: 0.88, green: 0.34, blue: 0.74),
            Color(red: 0.93, green: 0.39, blue: 0.56),
            Color(red: 0.80, green: 0.44, blue: 0.30),
            Color(red: 0.62, green: 0.54, blue: 0.29),
            Color(red: 0.39, green: 0.59, blue: 0.34),
            Color(red: 0.29, green: 0.53, blue: 0.53)
        ]
        return palette[index % palette.count]
    }

    private func loadOBSSettings() {
        let settings = OBSSettingsStorage.load()
        obsHost = settings.host
        obsPort = String(settings.port)
        obsPassword = settings.password
    }

    private func saveOBSSettings() {
        let trimmedHost = obsHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort = Int(obsPort) ?? OBSConnectionSettings.default.port
        let clampedPort = max(1, min(65535, parsedPort))
        let settings = OBSConnectionSettings(
            host: trimmedHost.isEmpty ? OBSConnectionSettings.default.host : trimmedHost,
            port: clampedPort,
            password: obsPassword
        )
        OBSSettingsStorage.save(settings)
    }

    #if canImport(AppKit)
    private func installDeleteKeyMonitorIfNeeded() {
        guard localDeleteKeyMonitor == nil else { return }
        localDeleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }
            let isDelete = event.keyCode == 51 || event.keyCode == 117
            let noModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            guard isDelete, noModifiers else { return event }
            guard viewModel.isLearnEnabled, viewModel.canRemoveLinkForSelectedCell else { return event }
            showDeleteLinkConfirmation = true
            return nil
        }
    }

    private func removeDeleteKeyMonitor() {
        guard let localDeleteKeyMonitor else { return }
        NSEvent.removeMonitor(localDeleteKeyMonitor)
        self.localDeleteKeyMonitor = nil
    }
    #endif
}

private struct EventCellView: View {
    let cellState: GridCellState
    let mappingTitle: String
    let mappingTargetID: String?
    let previewEvent: MIDIEvent?
    let obsRecordingActive: Bool
    let obsMuteActive: Bool?
    let isSelected: Bool
    let tileColor: Color
    let isLearnEnabled: Bool
    @State private var pulseScale: CGFloat = 1
    @State private var pulseOpacity: Double = 0
    @State private var displayedRelativePhase: CGFloat = 0
    @State private var now = Date()
    @State private var hitTintOpacity: Double = 0
    @State private var hitBorderOpacity: Double = 0
    @State private var hitBorderWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.08))

            RoundedRectangle(cornerRadius: 10)
                .fill(animationColor.opacity(hitTintOpacity))

            GeometryReader { geo in
                Rectangle()
                    .fill(animationColor)
                    .frame(height: geo.size.height * cellState.absoluteFill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(cellState.controllerMode == .absolute ? (0.9 * activityOpacity) : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Circle()
                .fill(animationColor)
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)
                .blur(radius: 0.8)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            GeometryReader { geo in
                let minSide = min(geo.size.width, geo.size.height)
                let bandWidth = max(3, minSide * 0.055)
                let period = bandWidth * 2
                let halfDiagonal = sqrt((geo.size.width * geo.size.width) + (geo.size.height * geo.size.height)) * 0.5
                let maxRadius = halfDiagonal + (bandWidth * 2)
                let signedShift = displayedRelativePhase * period * (cellState.relativeDirection >= 0 ? 1 : -1)
                let dynamicRange = Int((maxRadius + abs(signedShift)) / period) + 6
                let indexRange = (-dynamicRange)...dynamicRange

                ZStack {
                    ForEach(Array(indexRange), id: \.self) { idx in
                        let radius = (CGFloat(idx) * period) + signedShift + (bandWidth * 0.5)
                        if radius > 0, radius < maxRadius {
                            Circle()
                                .stroke(animationColor.opacity(0.55), lineWidth: bandWidth)
                                .frame(width: radius * 2, height: radius * 2)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                .opacity(cellState.controllerMode == .relative ? activityOpacity : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if hasVisibleContent {
                centerFunctionIcon()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: controllerIconName)
                                .font(.title3.weight(.semibold))
                            Text(controllerTitle)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.primary.opacity(0.9))
                    }
                    Spacer()
                    bottomInfoPanel
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(animationColor.opacity(hitBorderOpacity), lineWidth: hitBorderWidth)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .onChange(of: cellState.pulseNonce) {
            pulseScale = 0.72
            pulseOpacity = 0.5
            withAnimation(.easeOut(duration: 0.55)) {
                pulseScale = 1.35
                pulseOpacity = 0
            }
        }
        .onAppear {
            displayedRelativePhase = CGFloat(cellState.relativePhase)
        }
        .onChange(of: cellState.relativePhase) {
            withAnimation(.linear(duration: 0.16)) {
                displayedRelativePhase = CGFloat(cellState.relativePhase)
            }
        }
        .onChange(of: cellState.hitFeedbackNonce) {
            guard !isLearnEnabled else {
                hitTintOpacity = 0
                hitBorderOpacity = 0
                hitBorderWidth = 1.5
                return
            }
            hitTintOpacity = 0.22
            hitBorderOpacity = 0.9
            hitBorderWidth = 4.5
            withAnimation(.easeOut(duration: 0.42)) {
                hitTintOpacity = 0
                hitBorderOpacity = 0
                hitBorderWidth = 1.5
            }
        }
        .onChange(of: isLearnEnabled) {
            if isLearnEnabled {
                hitTintOpacity = 0
                hitBorderOpacity = 0
                hitBorderWidth = 1.5
            }
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { tick in
            now = tick
        }
    }

    private var activityOpacity: Double {
        guard let lastActivity = cellState.lastActivityAt else { return 0 }
        let age = now.timeIntervalSince(lastActivity)
        if age <= 2 { return 1 }
        if age >= 2.6 { return 0 }
        return max(0, 1 - ((age - 2) / 0.6))
    }

    private var hasVisibleContent: Bool {
        if isLearnEnabled && isSelected {
            return true
        }
        return effectiveEvent != nil
    }

    private var effectiveEvent: MIDIEvent? {
        previewEvent ?? cellState.event
    }

    private var isVolumeTarget: Bool {
        mappingTargetID?.hasPrefix("input.volume.set.") == true
    }

    private var isAudioWidgetTarget: Bool {
        guard let mappingTargetID else { return false }
        return mappingTargetID.hasPrefix("input.volume.set.")
            || mappingTargetID.hasPrefix("input.mute.toggle.")
    }

    private var controllerTitle: String {
        if let event = effectiveEvent, let trigger = event.trigger {
            return trigger.label
        }
        if let trigger = cellState.trigger {
            return trigger.label
        }
        return "-"
    }

    private var controllerIconName: String {
        if let event = effectiveEvent {
            return event.iconName
        }
        guard let trigger = cellState.trigger else {
            return "square.dashed"
        }
        switch trigger {
        case .note:
            return "pianokeys"
        case .controlChange:
            return "dial.medium"
        case .programChange:
            return "list.number"
        case .pitchBend, .mackieVPot, .mackieFader:
            return "slider.vertical.3"
        case .mackieTransport:
            return "button.horizontal.top.press.fill"
        }
    }

    private var animationColor: Color {
        guard isVolumeTarget else { return tileColor }
        switch cellState.absoluteFill {
        case ..<0.72:
            return Color(red: 0.17, green: 0.72, blue: 0.23)
        case ..<0.9:
            return Color(red: 0.88, green: 0.67, blue: 0.05)
        default:
            return Color(red: 0.82, green: 0.18, blue: 0.18)
        }
    }

    private var bottomInfoPanel: some View {
        if mappingTitle.isEmpty {
            return AnyView(EmptyView())
        }
        let (pluginName, targetName) = parsedMappingTitle(mappingTitle)
        return AnyView(VStack(alignment: .leading, spacing: 2) {
            Text(pluginName)
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)
            HStack(spacing: 8) {
                targetIcon()
                Text(targetName)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.95))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.28))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
        }
        )
    }

    private func parsedMappingTitle(_ value: String) -> (String, String) {
        let parts = value.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 {
            return (parts[0], parts[1])
        }
        return ("Mapping", value)
    }

    @ViewBuilder
    private func centerFunctionIcon() -> some View {
        if isLearnEnabled, let event = effectiveEvent {
            switch event.kind {
            case let .mackieTransport(action):
                switch action {
                case .record:
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 74, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.82))
                case .stop:
                    Image(systemName: "stop.fill")
                        .font(.system(size: 62, weight: .bold))
                        .foregroundStyle(animationColor.opacity(0.82))
                case .play:
                    Image(systemName: "play.fill")
                        .font(.system(size: 66, weight: .semibold))
                        .foregroundStyle(animationColor.opacity(0.82))
                case .rewind:
                    Image(systemName: "backward.fill")
                        .font(.system(size: 62, weight: .semibold))
                        .foregroundStyle(animationColor.opacity(0.82))
                case .fastForward:
                    Image(systemName: "forward.fill")
                        .font(.system(size: 62, weight: .semibold))
                        .foregroundStyle(animationColor.opacity(0.82))
                }
            default:
                EmptyView()
            }
        } else if let targetID = mappingTargetID, targetID.hasPrefix("input.volume.set.") {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 74, weight: .semibold))
                .foregroundStyle(animationColor.opacity(0.82))
        } else if let targetID = mappingTargetID, targetID.hasPrefix("input.mute.toggle.") {
            Image(systemName: (obsMuteActive ?? false) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 74, weight: .semibold))
                .foregroundStyle(animationColor.opacity(0.82))
        } else if let targetID = mappingTargetID, targetID.hasPrefix("scene.program.") {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 70, weight: .semibold))
                .foregroundStyle(animationColor.opacity(0.82))
        } else {
            switch mappingTargetID {
            case "recording.start":
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 74, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.82))
            case "recording.stop":
                Image(systemName: "stop.fill")
                    .font(.system(size: 62, weight: .bold))
                    .foregroundStyle(animationColor.opacity(0.82))
            case "recording.toggle":
                if obsRecordingActive {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 62, weight: .bold))
                        .foregroundStyle(.red.opacity(0.82))
                } else {
                    Image(systemName: "record.circle")
                        .font(.system(size: 74, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.82))
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func targetIcon() -> some View {
        if let targetID = mappingTargetID, targetID.hasPrefix("input.volume.set.") {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title3)
                .foregroundStyle(.primary.opacity(0.9))
        } else if let targetID = mappingTargetID, targetID.hasPrefix("input.mute.toggle.") {
            Image(systemName: (obsMuteActive ?? false) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.title3)
                .foregroundStyle(.primary.opacity(0.85))
        } else if let targetID = mappingTargetID, targetID.hasPrefix("scene.program.") {
            Image(systemName: "rectangle.3.group.fill")
                .font(.title3)
                .foregroundStyle(.primary.opacity(0.85))
        } else {
            switch mappingTargetID {
            case "recording.start":
            Image(systemName: "record.circle.fill")
                .font(.title3)
                .foregroundStyle(.red.opacity(0.9))
            case "recording.stop":
            Image(systemName: "stop.circle.fill")
                .font(.title3)
                .foregroundStyle(.primary.opacity(0.85))
            case "recording.toggle":
            Image(systemName: obsRecordingActive ? "stop.circle.fill" : "record.circle")
                .font(.title3)
                .foregroundStyle(.red.opacity(0.9))
            default:
                EmptyView()
            }
        }
    }
}

private struct MappingEditorView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mapping voor \(viewModel.selectedTriggerTitle())")
                .font(.headline)

            Picker("Plugin", selection: Binding(
                get: { viewModel.pluginIDForSelectedCell() },
                set: { viewModel.setPluginForSelectedCell(id: $0) }
            )) {
                ForEach(viewModel.availablePlugins) { plugin in
                    Text(plugin.name).tag(plugin.id)
                }
            }
            .pickerStyle(.menu)

            Menu {
                ForEach(viewModel.targetGroupsForSelectedCell()) { group in
                    Menu(group.title) {
                        ForEach(group.targets) { target in
                            Button(target.name) {
                                viewModel.setTargetForSelectedCell(id: target.id)
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Target")
                    Spacer()
                    Text(viewModel.targetTitleForSelectedCell())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            viewModel.refreshTargetsForSelectedCell()
        }
        .onChange(of: viewModel.selectedCellIndex) {
            viewModel.refreshTargetsForSelectedCell()
        }
        .onChange(of: viewModel.pluginIDForSelectedCell()) {
            viewModel.refreshTargetsForSelectedCell()
        }
    }
}

private struct OBSSettingsSheet: View {
    @Binding var host: String
    @Binding var port: String
    @Binding var password: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OBS Verbinding")
                .font(.headline)

            TextField("Host", text: $host)
                .textFieldStyle(.roundedBorder)

            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Annuleren") {
                    onCancel()
                }
                Button("Opslaan") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
