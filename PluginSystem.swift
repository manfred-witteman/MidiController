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
        guard let plugin = byID[pluginID] else { return nil }
        return plugin.targetGroups.first?.targets.first?.id
    }

    func targetName(pluginID: String, targetID: String) -> String? {
        guard let plugin = byID[pluginID] else { return nil }
        return plugin.targetGroups
            .flatMap(\.targets)
            .first(where: { $0.id == targetID })?
            .name
    }
}

struct OBSPlugin: ControllerPlugin {
    let id = "obs"
    let name = "OBS"

    let targetGroups: [PluginTargetGroup] = [
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

    func handle(event: MIDIEvent, targetID: String) {
        guard let command = OBSRecordingCommand(targetID: targetID) else { return }
        OBSWebSocketClient.shared.send(command: command)
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

private final class OBSWebSocketClient {
    static let shared = OBSWebSocketClient()

    private let queue = DispatchQueue(label: "OBSWebSocketClient.queue")
    private let session = URLSession.shared
    private var task: URLSessionWebSocketTask?
    private var isConnecting = false
    private var isIdentified = false
    private var pendingCommands: [OBSRecordingCommand] = []
    private var rpcVersion = 1
    private var didWarnAboutMissingPassword = false
    private var activeSettings = OBSSettingsStorage.load()

    private init() {}

    func send(command: OBSRecordingCommand) {
        queue.async {
            self.pendingCommands.append(command)
            self.ensureConnected()
        }
    }

    private func ensureConnected() {
        let latestSettings = OBSSettingsStorage.load()
        if latestSettings != activeSettings {
            activeSettings = latestSettings
            handleDisconnect("OBS settings changed, reconnecting")
        }

        if isIdentified {
            flushPendingCommands()
            return
        }
        if isConnecting {
            return
        }

        guard let url = URL(string: "ws://\(activeSettings.host):\(activeSettings.port)") else {
            log("invalid WebSocket URL")
            pendingCommands.removeAll()
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
            flushPendingCommands()
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
            "eventSubscriptions": 0
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

    private func flushPendingCommands() {
        guard isIdentified else { return }
        while !pendingCommands.isEmpty {
            let command = pendingCommands.removeFirst()
            sendRequest(command: command)
        }
    }

    private func sendRequest(command: OBSRecordingCommand) {
        sendJSON([
            "op": 6,
            "d": [
                "requestType": command.rawValue,
                "requestId": UUID().uuidString
            ]
        ])
    }

    private func handleRequestResponse(_ d: [String: Any]) {
        let requestType = d["requestType"] as? String ?? "UnknownRequest"
        let status = (d["requestStatus"] as? [String: Any]) ?? [:]
        let ok = (status["result"] as? Bool) ?? false
        if ok {
            log("request ok: \(requestType)")
            return
        }
        let comment = status["comment"] as? String ?? "unknown error"
        log("request failed (\(requestType)): \(comment)")
    }

    private func handleDisconnect(_ reason: String) {
        let closeCode = task?.closeCode.rawValue ?? 0
        log("\(reason) (closeCode=\(closeCode))")
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnecting = false
        isIdentified = false
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
}
