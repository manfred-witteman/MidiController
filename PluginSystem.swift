import Foundation

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

struct ControlMapping: Hashable {
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
                PluginTarget(id: "recording.start", name: "Start Recording"),
                PluginTarget(id: "recording.stop", name: "Stop Recording"),
                PluginTarget(id: "recording.toggle", name: "Toggle Recording")
            ]
        ),
        PluginTargetGroup(
            id: "streaming",
            title: "Streaming",
            targets: [
                PluginTarget(id: "stream.start", name: "Start Stream"),
                PluginTarget(id: "stream.stop", name: "Stop Stream"),
                PluginTarget(id: "stream.toggle", name: "Toggle Stream")
            ]
        ),
        PluginTargetGroup(
            id: "audio",
            title: "Audio",
            targets: [
                PluginTarget(id: "audio.master_up", name: "Master Volume +"),
                PluginTarget(id: "audio.master_down", name: "Master Volume -"),
                PluginTarget(id: "audio.master_set", name: "Set Master Volume")
            ]
        ),
        PluginTargetGroup(
            id: "scenes",
            title: "Scenes",
            targets: [
                PluginTarget(id: "scene.next", name: "Next Scene"),
                PluginTarget(id: "scene.previous", name: "Previous Scene")
            ]
        )
    ]

    func handle(event: MIDIEvent, targetID: String) {
        // Stub for real OBS WebSocket integration.
        print("OBS target='\(targetID)' event='\(event.title)' source='\(event.sourceName)'")
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
        print("Debug \(targetID): \(event.title)")
    }
}
