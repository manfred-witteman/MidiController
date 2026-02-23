import Foundation

#if canImport(Network)
import Network
#endif

#if canImport(Network)
@MainActor
final class DesktopBonjourBridge {
    private var listener: NWListener?
    private var hasRetriedWithDynamicPort = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let snapshotProvider: () -> RemoteSnapshot
    private let tapHandler: (Int) -> Void
    private let valueHandler: (Int, Double) -> Void
    private let systemHandler: (RemoteSystemAction) -> Void

    init(
        snapshotProvider: @escaping () -> RemoteSnapshot,
        tapHandler: @escaping (Int) -> Void,
        valueHandler: @escaping (Int, Double) -> Void,
        systemHandler: @escaping (RemoteSystemAction) -> Void
    ) {
        self.snapshotProvider = snapshotProvider
        self.tapHandler = tapHandler
        self.valueHandler = valueHandler
        self.systemHandler = systemHandler
    }

    func start() {
        guard listener == nil else { return }
        startListener(preferredFixedPort: true)
    }

    nonisolated func stop() {
        Task { @MainActor [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        receiveNext(on: connection)
    }

    private func startListener(preferredFixedPort: Bool) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener: NWListener
            if preferredFixedPort, let port = NWEndpoint.Port(rawValue: 55123) {
                listener = try NWListener(using: params, on: port)
            } else {
                listener = try NWListener(using: params)
            }
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "MidiController", type: "_midictrl._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handle(connection: connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                PluginLog.emit("REMOTE: listener state: \(state)")
                guard let self else { return }
                if case let .failed(error) = state,
                   preferredFixedPort,
                   case let NWError.posix(code) = error,
                   code == .EADDRINUSE {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard !self.hasRetriedWithDynamicPort else { return }
                        self.hasRetriedWithDynamicPort = true
                        self.listener?.cancel()
                        self.listener = nil
                        PluginLog.emit("REMOTE: port 55123 in use, retrying with dynamic port")
                        self.startListener(preferredFixedPort: false)
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            if preferredFixedPort, !hasRetriedWithDynamicPort {
                hasRetriedWithDynamicPort = true
                PluginLog.emit("REMOTE: fixed port failed, retrying with dynamic port: \(error.localizedDescription)")
                startListener(preferredFixedPort: false)
            } else {
                PluginLog.emit("REMOTE: failed to start Bonjour bridge: \(error.localizedDescription)")
            }
        }
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                self.receiveNext(on: connection)
                return
            }

            let response: RemoteResponse
            do {
                let command = try self.decoder.decode(RemoteCommand.self, from: data)
                response = self.process(command)
            } catch {
                response = .error("invalid_request")
            }

            do {
                let encoded = try self.encoder.encode(response)
                connection.send(content: encoded, completion: .contentProcessed { [weak self] sendError in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    if sendError != nil {
                        connection.cancel()
                        return
                    }
                    self.receiveNext(on: connection)
                })
            } catch {
                connection.cancel()
            }
        }
    }

    private func process(_ command: RemoteCommand) -> RemoteResponse {
        switch command {
        case .snapshot:
            return .snapshot(snapshotProvider())
        case let .tap(pad):
            tapHandler(pad)
            return .ack
        case let .setValue(pad, normalized):
            valueHandler(pad, max(0, min(1, normalized)))
            return .ack
        case let .system(action):
            systemHandler(action)
            return .ack
        }
    }
}
#else
@MainActor
final class DesktopBonjourBridge {
    init(snapshotProvider: @escaping () -> RemoteSnapshot, tapHandler: @escaping (Int) -> Void, valueHandler: @escaping (Int, Double) -> Void, systemHandler: @escaping (RemoteSystemAction) -> Void) {}
    func start() {}
    nonisolated func stop() {}
}
#endif
