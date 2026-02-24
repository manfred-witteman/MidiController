#if os(iOS)
import SwiftUI
import Network
import UIKit
import Combine

@MainActor
final class IOSRemoteViewModel: ObservableObject {
    @Published var pads: [RemotePadModel] = []
    @Published var connectionLabel: String = "Zoeken..."
    @Published var sceneName: String = "Scene"
    @Published var recordingActive: Bool = false
    @Published var canGoBack: Bool = true
    @Published var canGoNext: Bool = true

    // Caching and refresh control
    private var snapshotCache: [String: [RemotePadModel]] = [:]
    private var isRefreshing = false
    private var pendingRefresh = false
    private var emptySnapshotRetryCount = 0

    // Slider throttling
    private let sliderSubject = PassthroughSubject<(Int, Double), Never>()
    private var cancellables = Set<AnyCancellable>()

    private let browser: NWBrowser
    private var endpoint: NWEndpoint?
    private var endpointProbeToken = UUID()
    private let debugTag = "[REMOTE iOS]"

    init() {
        let parameters = NWParameters.tcp
        browser = NWBrowser(for: .bonjour(type: "_midictrl._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.connectionLabel = "Status: \(state)"
                self?.debug("browser state -> \(state)")
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                let endpoints = results.map(\.endpoint)
                if endpoints.isEmpty {
                    self.debug("bonjour endpoint -> none")
                    return
                }
                self.selectBestEndpoint(from: endpoints)
            }
        }
        browser.start(queue: .main)

        // Throttle slider updates to reduce network spam
        sliderSubject
            .throttle(for: .milliseconds(80), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] (padID, value) in
                self?.send(.setValue(pad: padID, normalized: value)) { _ in }
            }
            .store(in: &cancellables)
    }

    private func selectBestEndpoint(from endpoints: [NWEndpoint]) {
        let token = UUID()
        endpointProbeToken = token
        var bestEndpoint: NWEndpoint?
        var bestSnapshot: RemoteSnapshot?
        let group = DispatchGroup()

        for endpoint in endpoints {
            group.enter()
            send(.snapshot, to: endpoint) { response in
                defer { group.leave() }
                guard case let .snapshot(snapshot) = response else { return }
                if let current = bestSnapshot {
                    let currentStarted = current.serverStartedAt ?? .distantPast
                    let candidateStarted = snapshot.serverStartedAt ?? .distantPast
                    if candidateStarted > currentStarted ||
                        (candidateStarted == currentStarted && snapshot.generatedAt > current.generatedAt) {
                        bestSnapshot = snapshot
                        bestEndpoint = endpoint
                    }
                } else {
                    bestSnapshot = snapshot
                    bestEndpoint = endpoint
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard self.endpointProbeToken == token else { return }
            let resolvedEndpoint = bestEndpoint ?? endpoints.first
            guard let resolvedEndpoint else { return }
            self.endpoint = resolvedEndpoint
            self.connectionLabel = "Verbonden: \(resolvedEndpoint)"
            if let bestSnapshot {
                self.debug("bonjour endpoint selected -> \(resolvedEndpoint) server=\(bestSnapshot.serverInstanceID ?? "unknown") started=\(bestSnapshot.serverStartedAt?.description ?? "nil")")
            } else {
                self.debug("bonjour endpoint selected (no probe snapshot) -> \(resolvedEndpoint)")
            }
            self.refreshSnapshot()
        }
    }

    func refreshSnapshot() {
        debug("refreshSnapshot() requested; isRefreshing=\(isRefreshing) pending=\(pendingRefresh)")
        // Coalesce multiple refresh requests
        if isRefreshing {
            pendingRefresh = true
            debug("refreshSnapshot() coalesced")
            return
        }
        isRefreshing = true

        send(.snapshot) { [weak self] response in
            guard let self else { return }
            defer {
                self.isRefreshing = false
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.debug("refreshSnapshot() draining pending refresh")
                    self.refreshSnapshot()
                }
            }
            if case let .snapshot(snapshot) = response {
                let previousScene = self.sceneName
                let newScene = snapshot.sceneName ?? self.sceneName
                self.sceneName = newScene
                self.recordingActive = snapshot.recordingActive
                self.updateNavigationAvailability(scenes: snapshot.scenes, currentSceneIndex: snapshot.currentSceneIndex)
                self.debug("snapshot received scene=\(newScene) pads=\(snapshot.pads.count) recording=\(snapshot.recordingActive)")
                if !snapshot.pads.isEmpty {
                    let names = snapshot.pads.map(\.targetTitle).joined(separator: " | ")
                    self.debug("snapshot pad names [\(newScene)]: \(names)")
                }
                if !snapshot.pads.isEmpty {
                    self.pads = snapshot.pads
                    self.snapshotCache[newScene] = snapshot.pads
                    self.emptySnapshotRetryCount = 0
                    self.debug("snapshot applied scene=\(newScene) pads=\(snapshot.pads.count)")
                } else if let cached = self.snapshotCache[newScene], !cached.isEmpty {
                    self.pads = cached
                    self.debug("snapshot empty -> using cache scene=\(newScene) cachedPads=\(cached.count)")
                } else if !self.pads.isEmpty && newScene == previousScene {
                    // Keep current UI until we get a non-empty snapshot.
                    self.debug("snapshot empty -> keeping current pads=\(self.pads.count)")
                } else if newScene != previousScene {
                    // If scene changed and OBS reports no controls, show empty instead of stale pads.
                    self.pads = []
                    self.debug("snapshot empty after scene change -> cleared pads")
                } else if self.emptySnapshotRetryCount < 3 {
                    self.emptySnapshotRetryCount += 1
                    self.debug("snapshot empty and no cache -> retry \(self.emptySnapshotRetryCount)/3")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.refreshSnapshot()
                    }
                } else {
                    self.debug("snapshot empty after retries -> still no pads")
                }
            } else {
                self.debug("snapshot request returned non-snapshot response")
            }
        }
    }

    private func updateNavigationAvailability(scenes: [String]?, currentSceneIndex: Int?) {
        guard let scenes, !scenes.isEmpty, let currentSceneIndex else {
            canGoBack = true
            canGoNext = true
            return
        }
        canGoBack = currentSceneIndex > 0
        canGoNext = currentSceneIndex < scenes.count - 1
    }

    func applyCachedIfAvailable(for scene: String) {
        if let cached = snapshotCache[scene], !cached.isEmpty {
            self.pads = cached
        }
    }

    func tap(_ padID: Int) {
        debug("tap pad=\(padID)")
        // Optimistic: flip a boolean-ish pad locally if we can infer it from status/value
        if let idx = pads.firstIndex(where: { $0.id == padID }) {
            let current = pads[idx]
            if let val = current.normalizedValue, (val == 0 || val == 1) {
                pads[idx] = current.updatingNormalizedValue(val == 0 ? 1 : 0)
            }
        }
        send(.tap(pad: padID)) { [weak self] _ in
            self?.refreshSnapshot()
        }
    }

    func set(_ padID: Int, value: Double) {
        debug("set pad=\(padID) value=\(String(format: "%.3f", value))")
        // Optimistic: update local pad value immediately
        if let idx = pads.firstIndex(where: { $0.id == padID }) {
            let pad = pads[idx]
            pads[idx] = pad.updatingNormalizedValue(value)
        }
        // Throttle actual network calls
        sliderSubject.send((padID, value))
        if value <= 0.0001 {
            // Also send a tap to mute/toggle when sliding to zero, then refresh
            self.send(.tap(pad: padID)) { [weak self] _ in
                self?.refreshSnapshot()
            }
        }
    }

    func system(_ action: RemoteSystemAction) {
        debug("system action=\(action.rawValue)")
        // Optimistic: immediately reflect likely UI change for recording toggle
        if case .toggleRecording = action {
            recordingActive.toggle()
        }
        send(.system(action: action)) { [weak self] _ in
            guard let self else { return }
            // Try to show cached snapshot for current scene name (if server changes it, next refresh fixes it)
            self.applyCachedIfAvailable(for: self.sceneName)
            // Coalesced refresh
            self.refreshSnapshot()
            // Scene switches are async in OBS; fetch again shortly to avoid partial lists.
            if action == .previousScene || action == .nextScene {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.refreshSnapshot()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.60) { [weak self] in
                    self?.refreshSnapshot()
                }
            }
        }
    }

    private func send(_ command: RemoteCommand, completion: @escaping (RemoteResponse) -> Void) {
        guard let endpoint else {
            debug("send skipped (no endpoint) command=\(command.debugLabel)")
            Task { @MainActor in
                completion(.error("no_endpoint"))
            }
            return
        }
        send(command, to: endpoint, completion: completion)
    }

    private func send(_ command: RemoteCommand, to endpoint: NWEndpoint, completion: @escaping (RemoteResponse) -> Void) {
        debug("send command=\(command.debugLabel) endpoint=\(endpoint)")
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: .main)
        do {
            let payload = try JSONEncoder().encode(command)
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                    defer { connection.cancel() }
                    guard let data else {
                        Task { @MainActor [weak self] in
                            self?.debug("receive empty response for command=\(command.debugLabel)")
                        }
                        return
                    }
                    guard let response = try? JSONDecoder().decode(RemoteResponse.self, from: data) else {
                        Task { @MainActor [weak self] in
                            let raw = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
                            self?.debug("decode failed command=\(command.debugLabel) raw=\(raw)")
                        }
                        return
                    }
                    Task { @MainActor [weak self] in
                        self?.debug("receive response=\(response.debugLabel) for command=\(command.debugLabel)")
                    }
                    Task { @MainActor in completion(response) }
                }
            })
        } catch {
            debug("encode/send failed command=\(command.debugLabel) error=\(error.localizedDescription)")
            connection.cancel()
        }
    }

    private func debug(_ message: String) {
        print("\(debugTag) \(message)")
    }
}

// Helper to create a modified copy without mutating let properties
private extension RemotePadModel {
    func updatingNormalizedValue(_ newValue: Double?) -> RemotePadModel {
        // Recreate the struct with the same properties, changing only normalizedValue.
        // This relies on memberwise initializer synthesized by Swift.
        return RemotePadModel(
            id: self.id,
            title: self.title,
            triggerLabel: self.triggerLabel,
            triggerStyle: self.triggerStyle,
            targetTitle: self.targetTitle,
            hasMapping: self.hasMapping,
            statusText: self.statusText,
            normalizedValue: newValue
        )
    }
}

private extension RemoteCommand {
    var debugLabel: String {
        switch self {
        case .snapshot:
            return "snapshot"
        case let .tap(pad):
            return "tap(\(pad))"
        case let .setValue(pad, normalized):
            return "setValue(\(pad),\(String(format: "%.3f", normalized)))"
        case let .system(action):
            return "system(\(action.rawValue))"
        }
    }
}

private extension RemoteResponse {
    var debugLabel: String {
        switch self {
        case let .snapshot(snapshot):
            return "snapshot(scene=\(snapshot.sceneName ?? "nil"),pads=\(snapshot.pads.count),recording=\(snapshot.recordingActive))"
        case .ack:
            return "ack"
        case let .error(message):
            return "error(\(message))"
        }
    }
}

struct IOSRemoteHomeView: View {
    @StateObject private var vm = IOSRemoteViewModel()
    @State private var sliderValues: [Int: Double] = [:]
    @State private var overlayPad: RemotePadModel?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10),
        count: 2
    )

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(vm.sceneName)
                            .font(.system(size: 54, weight: .black, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.top, 18)

                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(vm.pads) { pad in
                                RemoteLampButtonCard(
                                    title: displayTitle(for: pad),
                                    status: pad.statusText,
                                    icon: actionIcon(for: pad),
                                    accent: accentColor(for: pad),
                                    isDimmed: (pad.normalizedValue ?? 1.0) <= 0.0001 || pad.statusText.lowercased() == "uit",
                                    onLeftToggle: {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        vm.tap(pad.id)
                                        vm.refreshSnapshot()
                                    },
                                    onRightOverlay: {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        sliderValues[pad.id] = pad.normalizedValue ?? sliderValues[pad.id] ?? 0.5
                                        overlayPad = pad
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 120)
                }
                .background(
                    ZStack {
                        Image("RemoteBackground")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .ignoresSafeArea()
                        Color.clear
                            .background(Material.regular)
                            .opacity(0.28)
                            .ignoresSafeArea()
                    }
                )
                .overlay(alignment: .bottom) {
                    RemoteBottomBar(
                        isRecording: vm.recordingActive,
                        isBackEnabled: vm.canGoBack,
                        isNextEnabled: vm.canGoNext,
                        onBack: {
                            vm.system(.previousScene)
                        },
                        onRecord: {
                            vm.system(.toggleRecording)
                        },
                        onNext: {
                            vm.system(.nextScene)
                        }
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }

                if let pad = overlayPad {
                    RemoteSliderOverlay(
                        title: displayTitle(for: pad),
                        accent: accentColor(for: pad),
                        value: Binding(
                            get: { sliderValues[pad.id] ?? 0.5 },
                            set: {
                                sliderValues[pad.id] = $0
                                vm.set(pad.id, value: $0)
                            }
                        ),
                        dismiss: {
                            overlayPad = nil
                            vm.refreshSnapshot()
                        }
                    )
                    .transition(.opacity)
                    .zIndex(20)
                }
            }
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) {
                Text(vm.connectionLabel)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 3)
            }
            .onAppear {
                vm.refreshSnapshot()
            }
        }
    }

    private func displayTitle(for pad: RemotePadModel) -> String {
        let raw = pad.targetTitle
        if let idx = raw.firstIndex(of: ":") {
            let content = raw[raw.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? raw : content
        }
        return raw
    }

    private func actionIcon(for pad: RemotePadModel) -> String {
        let title = displayTitle(for: pad).lowercased()
        if title.contains("record") { return "record.circle.fill" }
        if title.contains("play") { return "play.circle.fill" }
        if title.contains("stop") { return "stop.circle.fill" }
        if title.contains("mute") { return "speaker.slash.fill" }
        if title.contains("volume") || title.contains("audio") || title.contains("mic") { return "speaker.wave.3.fill" }
        if title.contains("scene") { return "movieclapper.fill" }
        return "switch.2"
    }

    private func accentColor(for pad: RemotePadModel) -> Color {
        switch pad.id % 6 {
        case 0: return .green
        case 1: return .red
        case 2: return .blue
        case 3: return .orange
        case 4: return .purple
        default: return .gray
        }
    }

}

private struct RemoteLampButtonCard: View {
    let title: String
    let status: String
    let icon: String
    let accent: Color
    let isDimmed: Bool
    let onLeftToggle: () -> Void
    let onRightOverlay: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.white.opacity(isDimmed ? 0.55 : 0.88))

            HStack(spacing: 10) {
                Button(action: onLeftToggle) {
                    ZStack {
                        Circle()
                            .fill(accent)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Circle().fill(Color.white.opacity(isDimmed ? 0.35 : 0))
                            )
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)

                Button(action: onRightOverlay) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                        Text(status)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
        }
        .opacity(isDimmed ? 0.7 : 1.0)
        .frame(height: 63)
    }
}

private struct RemoteBottomBar: View {
    let isRecording: Bool
    var isBackEnabled: Bool = true
    var isNextEnabled: Bool = true
    let onBack: () -> Void
    let onRecord: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack {
            barButton(icon: "backward.fill", label: "back", color: .white, enabled: isBackEnabled, action: onBack)
            barButton(icon: "record.circle.fill", label: isRecording ? "stop" : "record", color: .red, enabled: true, action: onRecord)
            barButton(icon: "forward.fill", label: "next", color: .white, enabled: isNextEnabled, action: onNext)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .background(Color.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    @ViewBuilder
    private func barButton(icon: String, label: String, color: Color, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: {
            // Use a slightly stronger feedback for record, light for others
            if icon == "record.circle.fill" {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            action()
        }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(color.opacity(0.95))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.45)
    }
}

private struct RemoteSliderOverlay: View {
    let title: String
    let accent: Color
    @Binding var value: Double
    let dismiss: () -> Void

    var body: some View {
        VStack {
            Text(title)
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.top, 92)

            Text("\(Int(value * 100))%")
                .font(.headline.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.top, 4)
                .padding(.bottom, 24)

            RemoteVerticalSlider(value: $value, icon: "slider.vertical.3", iconColor: accent)
                .frame(width: 132, height: 390)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.62))
        .ignoresSafeArea()
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            dismiss()
        }
    }
}

private struct RemoteVerticalSlider: View {
    @Binding var value: Double
    let icon: String
    let iconColor: Color

    @State private var startingValue = 0.0

    private func dragGesture(geometry: GeometryProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0)
            .onEnded { _ in
                startingValue = value
            }
            .sequenced(before: DragGesture(minimumDistance: 0)
                .onChanged {
                    let next = startingValue - Double(($0.location.y - $0.startLocation.y) / geometry.size.height)
                    value = min(max(0.0, next), 1.0)
                }
            )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color(red: 24/255, green: 24/255, blue: 24/255)
                Color(red: 221/255, green: 221/255, blue: 221/255)
                    .frame(height: geometry.size.height * value)
                Image(systemName: icon)
                    .font(.system(size: geometry.size.width / 3.0, weight: .regular))
                    .foregroundStyle(iconColor)
                    .offset(y: -geometry.size.height / 5.0)
                    .animation(.easeIn(duration: 0.2), value: value)
            }
            .cornerRadius(geometry.size.width / 5.0)
            .gesture(AnyGesture(dragGesture(geometry: geometry).map { _ in () }))
        }
    }
}
#endif
