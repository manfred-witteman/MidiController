import CryptoKit
import Foundation

enum PluginLog {
    static let didEmit = Notification.Name("PluginLog.didEmit")

    static func emit(_ line: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didEmit, object: line)
        }
    }
}

enum OBSTargetCatalog {
    static let didChange = Notification.Name("OBSTargetCatalog.didChange")

    static func emitDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

enum OBSState {
    static let recordingDidChange = Notification.Name("OBSState.recordingDidChange")
    static let inputMuteDidChange = Notification.Name("OBSState.inputMuteDidChange")

    static func emitRecording(active: Bool) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: recordingDidChange, object: active)
        }
    }

    static func emitInputMute(inputName: String, muted: Bool) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: inputMuteDidChange,
                object: nil,
                userInfo: [
                    "inputName": inputName,
                    "muted": muted
                ]
            )
        }
    }
}

struct OBSConnectionSettings: Equatable {
    var host: String
    var port: Int
    var password: String

    static let `default` = OBSConnectionSettings(
        host: "127.0.0.1",
        port: 4455,
        password: ""
    )
}

enum OBSSettingsStorage {
    private static let hostKey = "OBSWebSocketHost"
    private static let portKey = "OBSWebSocketPort"
    private static let passwordKey = "OBSWebSocketPassword"

    static func load() -> OBSConnectionSettings {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: hostKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedPort = defaults.object(forKey: portKey) as? Int
        let password = defaults.string(forKey: passwordKey) ?? ""
        let resolvedHost = (host?.isEmpty == false) ? (host ?? OBSConnectionSettings.default.host) : OBSConnectionSettings.default.host
        let resolvedPort = (storedPort ?? 0) > 0 ? (storedPort ?? OBSConnectionSettings.default.port) : OBSConnectionSettings.default.port
        return OBSConnectionSettings(
            host: resolvedHost,
            port: resolvedPort,
            password: password
        )
    }

    static func save(_ settings: OBSConnectionSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.host, forKey: hostKey)
        defaults.set(settings.port, forKey: portKey)
        defaults.set(settings.password, forKey: passwordKey)
    }
}

struct PluginTarget: Identifiable, Hashable {
    let id: String
    let name: String
}

struct PluginTargetGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let targets: [PluginTarget]
}

protocol ControllerPlugin {
    var id: String { get }
    var name: String { get }
    var targetGroups: [PluginTargetGroup] { get }
    func handle(event: MIDIEvent, targetID: String)
}

protocol DynamicTargetPlugin {
    func currentTargetGroups() -> [PluginTargetGroup]
    func refreshTargetGroups()
}

struct ControlMapping: Hashable, Codable {
    let pluginID: String
    let targetID: String
}

final class PluginRegistry {
    let plugins: [ControllerPlugin]
    private let byID: [String: ControllerPlugin]

    init() {
        let allPlugins: [ControllerPlugin] = [
            OBSPlugin(),
            DebugPlugin()
        ]
        self.plugins = allPlugins
        self.byID = Dictionary(uniqueKeysWithValues: allPlugins.map { ($0.id, $0) })
    }

    func plugin(id: String) -> ControllerPlugin? {
        byID[id]
    }

    func firstTargetID(pluginID: String) -> String? {
        targetGroups(pluginID: pluginID).first?.targets.first?.id
    }

    func targetName(pluginID: String, targetID: String) -> String? {
        guard byID[pluginID] != nil else { return nil }
        if let name = targetGroups(pluginID: pluginID)
            .flatMap(\.targets)
            .first(where: { $0.id == targetID })?
            .name {
            return name
        }
        if pluginID == "obs" {
            return OBSPlugin.displayName(for: targetID)
        }
        return nil
    }

    func targetGroups(pluginID: String) -> [PluginTargetGroup] {
        guard let plugin = byID[pluginID] else { return [] }
        if let dynamicPlugin = plugin as? DynamicTargetPlugin {
            return dynamicPlugin.currentTargetGroups()
        }
        return plugin.targetGroups
    }

    func refreshTargets(pluginID: String) {
        guard let plugin = byID[pluginID], let dynamicPlugin = plugin as? DynamicTargetPlugin else {
            return
        }
        dynamicPlugin.refreshTargetGroups()
    }
}

struct OBSPlugin: ControllerPlugin, DynamicTargetPlugin {
    let id = "obs"
    let name = "OBS"

    static let baseTargetGroups: [PluginTargetGroup] = [
        PluginTargetGroup(
            id: "recording",
            title: "Recording",
            targets: [
                PluginTarget(id: "recording.toggle", name: "Toggle Recording"),
                PluginTarget(id: "recording.start", name: "Start Recording"),
                PluginTarget(id: "recording.stop", name: "Stop Recording")
            ]
        )
    ]

    var targetGroups: [PluginTargetGroup] { Self.baseTargetGroups }

    func handle(event: MIDIEvent, targetID: String) {
        if let command = OBSRecordingCommand(targetID: targetID) {
            OBSWebSocketClient.shared.send(command: command)
            return
        }
        if let route = OBSDynamicRoute(targetID: targetID) {
            OBSWebSocketClient.shared.send(route: route, event: event)
        }
    }

    func currentTargetGroups() -> [PluginTargetGroup] {
        OBSWebSocketClient.shared.currentTargetGroups()
    }

    func refreshTargetGroups() {
        OBSWebSocketClient.shared.refreshDynamicTargets()
    }

    static func displayName(for targetID: String) -> String? {
        if targetID == "recording.toggle" { return "Toggle Recording" }
        if targetID == "recording.start" { return "Start Recording" }
        if targetID == "recording.stop" { return "Stop Recording" }
        if let route = OBSDynamicRoute(targetID: targetID) {
            return route.displayName
        }
        return nil
    }
}

struct DebugPlugin: ControllerPlugin {
    let id = "debug"
    let name = "Debug"
    let targetGroups: [PluginTargetGroup] = [
        PluginTargetGroup(
            id: "logging",
            title: "Logging",
            targets: [
                PluginTarget(id: "log.event", name: "Print Event")
            ]
        )
    ]

    func handle(event: MIDIEvent, targetID: String) {
        let line = "Debug \(targetID): \(event.title)"
        print(line)
        PluginLog.emit(line)
    }
}

private enum OBSRecordingCommand: String {
    case start = "StartRecord"
    case stop = "StopRecord"
    case toggle = "ToggleRecord"

    init?(targetID: String) {
        switch targetID {
        case "recording.start":
            self = .start
        case "recording.stop":
            self = .stop
        case "recording.toggle":
            self = .toggle
        default:
            return nil
        }
    }
}

private enum OBSDynamicRoute {
    case setProgramScene(String)
    case toggleInputMute(String)
    case setInputVolume(String)

    var requestType: String {
        switch self {
        case .setProgramScene:
            return "SetCurrentProgramScene"
        case .toggleInputMute:
            return "ToggleInputMute"
        case .setInputVolume:
            return "SetInputVolume"
        }
    }

    var displayName: String {
        switch self {
        case let .setProgramScene(sceneName):
            return "Scene: \(sceneName)"
        case let .toggleInputMute(inputName):
            return "Mute: \(inputName)"
        case let .setInputVolume(inputName):
            return inputName
        }
    }

    var logLabel: String {
        switch self {
        case .setProgramScene:
            return "Set Scene"
        case .toggleInputMute:
            return "Toggle Mute"
        case .setInputVolume:
            return "Set Volume"
        }
    }

    var targetID: String {
        switch self {
        case let .setProgramScene(sceneName):
            return "scene.program.\(Self.encode(sceneName))"
        case let .toggleInputMute(inputName):
            return "input.mute.toggle.\(Self.encode(inputName))"
        case let .setInputVolume(inputName):
            return "input.volume.set.\(Self.encode(inputName))"
        }
    }

    init?(targetID: String) {
        if targetID.hasPrefix("scene.program.") {
            let encoded = String(targetID.dropFirst("scene.program.".count))
            guard let decoded = Self.decode(encoded) else { return nil }
            self = .setProgramScene(decoded)
            return
        }
        if targetID.hasPrefix("input.mute.toggle.") {
            let encoded = String(targetID.dropFirst("input.mute.toggle.".count))
            guard let decoded = Self.decode(encoded) else { return nil }
            self = .toggleInputMute(decoded)
            return
        }
        if targetID.hasPrefix("input.volume.set.") {
            let encoded = String(targetID.dropFirst("input.volume.set.".count))
            guard let decoded = Self.decode(encoded) else { return nil }
            self = .setInputVolume(decoded)
            return
        }
        return nil
    }

    private static let allowedEncodingCharacterSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: allowedEncodingCharacterSet) ?? raw
    }

    private static func decode(_ encoded: String) -> String? {
        encoded.removingPercentEncoding
    }

}

private enum OBSOutgoingRequest {
    case recording(OBSRecordingCommand)
    case dynamic(OBSDynamicRoute, MIDIEvent)
}

private final class OBSWebSocketClient {
    static let shared = OBSWebSocketClient()

    private let queue = DispatchQueue(label: "OBSWebSocketClient.queue")
    private let session = URLSession.shared
    private var task: URLSessionWebSocketTask?
    private var isConnecting = false
    private var isIdentified = false
    private var pendingRequests: [OBSOutgoingRequest] = []
    private var responseHandlers: [String: ([String: Any]) -> Void] = [:]
    private var requestDisplayNames: [String: String] = [:]
    private var quietSuccessRequests = Set<String>()
    private var sceneNames: [String] = []
    private var inputNames: [String] = []
    private var inputVolumeCache: [String: Double] = [:]
    private var inputMuteStates: [String: Bool] = [:]
    private var ccModeTrackers: [String: CCModeTracker] = [:]
    private var isRecordingActive = false
    private var rpcVersion = 1
    private var didWarnAboutMissingPassword = false
    private var activeSettings = OBSSettingsStorage.load()

    private init() {}

    func send(command: OBSRecordingCommand) {
        queue.async {
            self.pendingRequests.append(.recording(command))
            self.ensureConnected()
        }
    }

    func send(route: OBSDynamicRoute, event: MIDIEvent) {
        queue.async {
            self.pendingRequests.append(.dynamic(route, event))
            self.ensureConnected()
        }
    }

    func currentTargetGroups() -> [PluginTargetGroup] {
        queue.sync {
            var groups = OBSPlugin.baseTargetGroups
            if !sceneNames.isEmpty {
                groups.append(
                    PluginTargetGroup(
                        id: "scenes",
                        title: "Scenes",
                        targets: sceneNames.map { name in
                            PluginTarget(id: OBSDynamicRoute.setProgramScene(name).targetID, name: "Scene: \(name)")
                        }
                    )
                )
            }
            if !inputNames.isEmpty {
                groups.append(
                    PluginTargetGroup(
                        id: "volume",
                        title: "Volume",
                        targets: inputNames.map { name in
                            PluginTarget(id: OBSDynamicRoute.setInputVolume(name).targetID, name: name)
                        }
                    )
                )
                groups.append(
                    PluginTargetGroup(
                        id: "mute",
                        title: "Mute",
                        targets: inputNames.map { name in
                            PluginTarget(id: OBSDynamicRoute.toggleInputMute(name).targetID, name: "Mute: \(name)")
                        }
                    )
                )
            }
            return groups
        }
    }

    func refreshDynamicTargets() {
        queue.async {
            self.ensureConnected()
            guard self.isIdentified else { return }
            self.requestSceneList()
            self.requestInputList()
        }
    }

    private func ensureConnected() {
        let latestSettings = OBSSettingsStorage.load()
        if latestSettings != activeSettings {
            activeSettings = latestSettings
            handleDisconnect("OBS settings changed, reconnecting")
        }

        if isIdentified {
            flushPendingRequests()
            return
        }
        if isConnecting {
            return
        }

        guard let url = URL(string: "ws://\(activeSettings.host):\(activeSettings.port)") else {
            log("invalid WebSocket URL")
            pendingRequests.removeAll()
            return
        }

        log("connecting to \(activeSettings.host):\(activeSettings.port)")
        let webSocketTask = session.webSocketTask(with: url)
        task = webSocketTask
        isConnecting = true
        isIdentified = false
        webSocketTask.resume()
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case let .failure(error):
                    let nsError = error as NSError
                    let detail = "receive error: \(nsError.localizedDescription) [domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)]"
                    self.handleDisconnect(detail)
                case let .success(message):
                    self.handleIncoming(message)
                    self.receiveNextMessage()
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .string(text):
            data = Data(text.utf8)
        case let .data(binary):
            data = binary
        @unknown default:
            return
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let op = root["op"] as? Int
        else {
            return
        }

        switch op {
        case 0: // Hello
            handleHello(root["d"] as? [String: Any] ?? [:])
        case 2: // Identified
            isConnecting = false
            isIdentified = true
            log("connected (\(activeSettings.host):\(activeSettings.port))")
            flushPendingRequests()
            requestSceneList()
            requestInputList()
            requestRecordStatus()
        case 5: // Event
            if let d = root["d"] as? [String: Any] {
                handleEvent(d)
            }
        case 7: // RequestResponse
            if let d = root["d"] as? [String: Any] {
                handleRequestResponse(d)
            }
        default:
            break
        }
    }

    private func handleHello(_ d: [String: Any]) {
        if let serverRPCVersion = d["rpcVersion"] as? Int {
            rpcVersion = serverRPCVersion
        }

        var identifyData: [String: Any] = [
            "rpcVersion": rpcVersion,
            "eventSubscriptions": 72
        ]

        if let auth = d["authentication"] as? [String: Any] {
            guard let challenge = auth["challenge"] as? String, let salt = auth["salt"] as? String else {
                handleDisconnect("OBS auth handshake missing challenge/salt")
                return
            }
            guard !activeSettings.password.isEmpty else {
                if !didWarnAboutMissingPassword {
                    log("server vraagt wachtwoord. Stel dit in via OBS instellingen in de app, of schakel auth uit in OBS.")
                    didWarnAboutMissingPassword = true
                }
                handleDisconnect("OBS auth required but no password configured")
                return
            }
            identifyData["authentication"] = makeAuthentication(password: activeSettings.password, challenge: challenge, salt: salt)
        }

        sendJSON([
            "op": 1,
            "d": identifyData
        ])
    }

    private func flushPendingRequests() {
        guard isIdentified else { return }
        while !pendingRequests.isEmpty {
            let request = pendingRequests.removeFirst()
            switch request {
            case let .recording(command):
                sendRequest(command: command)
            case let .dynamic(route, event):
                sendDynamicRequest(route: route, event: event)
            }
        }
    }

    private func sendRequest(command: OBSRecordingCommand) {
        sendRequest(
            requestType: command.rawValue,
            requestData: nil,
            displayName: command.rawValue,
            quietSuccessLog: false,
            responseHandler: nil
        )
    }

    private func sendDynamicRequest(route: OBSDynamicRoute, event: MIDIEvent) {
        let requestType: String
        let requestData: [String: Any]
        switch route {
        case let .setProgramScene(sceneName):
            requestType = route.requestType
            requestData = ["sceneName": sceneName]
        case let .toggleInputMute(inputName):
            requestType = "SetInputMute"
            let muted = resolveMutedStateForToggle(inputName: inputName, event: event)
            requestData = [
                "inputName": inputName,
                "inputMuted": muted
            ]
            setInputMuted(inputName: inputName, muted: muted)
            log("mute set request (\(inputName)): \(muted ? "ON" : "OFF")")
        case let .setInputVolume(inputName):
            requestType = route.requestType
            guard let volume = resolveInputVolume(for: inputName, event: event) else {
                log("volume skip (\(inputName)): unsupported event \(event.kind)")
                return
            }
            log(
                String(
                    format: "volume set request (\(inputName)): %.3f via %@",
                    volume,
                    String(describing: event.kind)
                )
            )
            requestData = [
                "inputName": inputName,
                "inputVolumeMul": volume
            ]
        }
        sendRequest(
            requestType: requestType,
            requestData: requestData,
            displayName: route.logLabel,
            quietSuccessLog: false,
            responseHandler: nil
        )
    }

    private func sendRequest(
        requestType: String,
        requestData: [String: Any]?,
        displayName: String,
        quietSuccessLog: Bool,
        responseHandler: (([String: Any]) -> Void)?
    ) {
        let requestID = UUID().uuidString
        requestDisplayNames[requestID] = displayName
        if quietSuccessLog {
            quietSuccessRequests.insert(requestID)
        }
        if let responseHandler {
            responseHandlers[requestID] = responseHandler
        }
        var requestBody: [String: Any] = [
            "requestType": requestType,
            "requestId": requestID
        ]
        if let requestData {
            requestBody["requestData"] = requestData
        }
        sendJSON([
            "op": 6,
            "d": requestBody
        ])
    }

    private func handleRequestResponse(_ d: [String: Any]) {
        let requestID = d["requestId"] as? String ?? ""
        let requestType = d["requestType"] as? String ?? "UnknownRequest"
        let displayName = requestDisplayNames.removeValue(forKey: requestID) ?? requestType
        let isQuiet = quietSuccessRequests.remove(requestID) != nil
        let responseHandler = responseHandlers.removeValue(forKey: requestID)
        let status = (d["requestStatus"] as? [String: Any]) ?? [:]
        let ok = (status["result"] as? Bool) ?? false
        let responseData = (d["responseData"] as? [String: Any]) ?? [:]
        if ok {
            responseHandler?(responseData)
            if !isQuiet {
                log("request ok: \(displayName)")
            }
            return
        }
        let comment = status["comment"] as? String ?? "unknown error"
        log("request failed (\(displayName)): \(comment)")
    }

    private func handleDisconnect(_ reason: String) {
        let closeCode = task?.closeCode.rawValue ?? 0
        log("\(reason) (closeCode=\(closeCode))")
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnecting = false
        isIdentified = false
        sceneNames = []
        inputNames = []
        inputVolumeCache.removeAll()
        inputMuteStates.removeAll()
        ccModeTrackers.removeAll()
        setRecordingActive(false)
        OBSTargetCatalog.emitDidChange()
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonText = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(jsonText)) { [weak self] error in
            guard let self else { return }
            if let error {
                self.queue.async {
                    self.handleDisconnect("send error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func makeAuthentication(password: String, challenge: String, salt: String) -> String {
        let secret = sha256Base64("\(password)\(salt)")
        return sha256Base64("\(secret)\(challenge)")
    }

    private func sha256Base64(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
    }

    private func log(_ message: String) {
        let line = "OBS: \(message)"
        print(line)
        PluginLog.emit(line)
    }

    private func requestSceneList() {
        sendRequest(
            requestType: "GetSceneList",
            requestData: nil,
            displayName: "GetSceneList",
            quietSuccessLog: true
        ) { [weak self] responseData in
            guard let self else { return }
            let names = ((responseData["scenes"] as? [[String: Any]]) ?? [])
                .compactMap { $0["sceneName"] as? String }
            self.sceneNames = names
            OBSTargetCatalog.emitDidChange()
        }
    }

    private func requestInputList() {
        sendRequest(
            requestType: "GetInputList",
            requestData: nil,
            displayName: "GetInputList",
            quietSuccessLog: true
        ) { [weak self] responseData in
            guard let self else { return }
            let names = ((responseData["inputs"] as? [[String: Any]]) ?? [])
                .compactMap { $0["inputName"] as? String }
                .sorted()
            self.inputNames = names
            for name in names {
                self.requestInputMuteState(inputName: name)
            }
            OBSTargetCatalog.emitDidChange()
        }
    }

    private func requestRecordStatus() {
        sendRequest(
            requestType: "GetRecordStatus",
            requestData: nil,
            displayName: "GetRecordStatus",
            quietSuccessLog: true
        ) { [weak self] responseData in
            guard let self else { return }
            let active = (responseData["outputActive"] as? Bool) ?? false
            self.setRecordingActive(active)
        }
    }

    private func handleEvent(_ d: [String: Any]) {
        guard let eventType = d["eventType"] as? String else { return }
        guard let eventData = d["eventData"] as? [String: Any] else { return }
        if eventType == "RecordStateChanged" {
            let active = (eventData["outputActive"] as? Bool) ?? false
            setRecordingActive(active)
            return
        }
        if eventType == "InputMuteStateChanged" {
            guard let inputName = eventData["inputName"] as? String else { return }
            let muted = (eventData["inputMuted"] as? Bool) ?? false
            setInputMuted(inputName: inputName, muted: muted)
        }
    }

    private func setRecordingActive(_ active: Bool) {
        guard active != isRecordingActive else { return }
        isRecordingActive = active
        OBSState.emitRecording(active: active)
        log("recording state: \(active ? "ON" : "OFF")")
    }

    private func requestInputMuteState(inputName: String) {
        sendRequest(
            requestType: "GetInputMute",
            requestData: ["inputName": inputName],
            displayName: "GetInputMute",
            quietSuccessLog: true
        ) { [weak self] responseData in
            guard let self else { return }
            let muted = (responseData["inputMuted"] as? Bool) ?? false
            self.setInputMuted(inputName: inputName, muted: muted)
        }
    }

    private func setInputMuted(inputName: String, muted: Bool) {
        let previous = inputMuteStates[inputName]
        inputMuteStates[inputName] = muted
        if previous != muted {
            OBSState.emitInputMute(inputName: inputName, muted: muted)
        }
    }

    private func resolveInputVolume(for inputName: String, event: MIDIEvent) -> Double? {
        switch event.kind {
        case let .controlChange(_, _, value):
            let key = controlKey(for: event)
            if modeForControlEvent(key: key, value: value) == .relative {
                let delta = relativeControlDelta(value)
                return adjustCachedInputVolume(inputName: inputName, delta: delta)
            }
            let normalized = clamp01(Double(value) / 127.0)
            let mul = volumeMulFromKnob(normalized)
            inputVolumeCache[inputName] = mul
            return mul
        case let .pitchBend(_, value):
            let normalized = clamp01(Double(value) / 16383.0)
            let mul = volumeMulFromKnob(normalized)
            inputVolumeCache[inputName] = mul
            return mul
        case let .mackieFader(_, value):
            let normalized = clamp01(Double(value) / 16383.0)
            let mul = volumeMulFromKnob(normalized)
            inputVolumeCache[inputName] = mul
            return mul
        case let .mackieVPot(_, value):
            let delta = mackieRelativeDelta(value)
            return adjustCachedInputVolume(inputName: inputName, delta: delta)
        default:
            return nil
        }
    }

    private func resolveMutedStateForToggle(inputName: String, event: MIDIEvent) -> Bool {
        switch event.kind {
        case let .controlChange(_, _, value):
            let key = controlKey(for: event)
            if modeForControlEvent(key: key, value: value) == .relative {
                let delta = relativeControlDelta(value)
                let current = inputMuteStates[inputName] ?? false
                if delta == 0 { return current }
                if delta > 0 { return false }
                return true
            }
            return value >= 64
        case let .pitchBend(_, value):
            return value >= 8192
        case let .mackieFader(_, value):
            return value >= 8192
        default:
            let current = inputMuteStates[inputName] ?? false
            return !current
        }
    }

    private func adjustCachedInputVolume(inputName: String, delta: Int) -> Double {
        let currentMul = inputVolumeCache[inputName] ?? volumeMulFromKnob(0.8)
        let currentDB = dbFromMul(currentMul)
        let nextDB = clampDB(currentDB + (Double(delta) * 1.25))
        let nextMul = mulFromDB(nextDB)
        inputVolumeCache[inputName] = nextMul
        return nextMul
    }

    private func clamp01(_ value: Double) -> Double {
        max(0, min(1, value))
    }

    private func looksLikeRelativeCC(_ value: Int) -> Bool {
        (1...8).contains(value) || (65...72).contains(value)
    }

    private func relativeControlDelta(_ value: Int) -> Int {
        if value == 64 { return 0 }
        if value < 64 { return value }
        return -(value - 64)
    }

    private func mackieRelativeDelta(_ value: Int) -> Int {
        if value <= 0x3F {
            return value
        }
        return -(value & 0x3F)
    }

    private func volumeMulFromKnob(_ normalized: Double) -> Double {
        if normalized <= 0.001 { return 0 }
        let db = -60.0 + (normalized * 60.0)
        return mulFromDB(db)
    }

    private func mulFromDB(_ db: Double) -> Double {
        if db <= -60 { return 0 }
        return pow(10.0, db / 20.0)
    }

    private func dbFromMul(_ mul: Double) -> Double {
        if mul <= 0 { return -60 }
        return clampDB(20.0 * log10(mul))
    }

    private func clampDB(_ db: Double) -> Double {
        max(-60, min(0, db))
    }

    private func controlKey(for event: MIDIEvent) -> String {
        guard case let .controlChange(channel, controller, _) = event.kind else {
            return "\(event.sourceID):unknown"
        }
        return "\(event.sourceID):\(channel):\(controller)"
    }

    private func modeForControlEvent(key: String, value: Int) -> CCInputMode {
        var tracker = ccModeTrackers[key] ?? CCModeTracker()
        if tracker.mode == .absolute {
            return .absolute
        }
        if tracker.mode == .relative {
            return .relative
        }

        if !looksLikeRelativeCC(value) {
            tracker.mode = .absolute
            ccModeTrackers[key] = tracker
            return .absolute
        }

        tracker.relativeCandidateCount += 1
        if tracker.relativeCandidateCount >= 3 {
            tracker.mode = .relative
            ccModeTrackers[key] = tracker
            return .relative
        }

        ccModeTrackers[key] = tracker
        return .absolute
    }
}

private enum CCInputMode {
    case unknown
    case absolute
    case relative
}

private struct CCModeTracker {
    var mode: CCInputMode = .unknown
    var relativeCandidateCount = 0
}
