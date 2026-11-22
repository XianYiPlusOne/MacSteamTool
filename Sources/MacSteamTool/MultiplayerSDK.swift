import CMultiplayer
import Darwin
import Foundation
import MacSteamToolCore

/// The adapter has no session state. Keep its image mapped across SDK restarts.
final class MultiplayerSDK {
    let api: MPFunctions
    private let image: UnsafeMutableRawPointer
    private var initialized = false

    init(url: URL) throws {
        guard let image = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw AppFailure("无法加载 Steamworks 联机组件 / " + String(cString: dlerror()))
        }
        guard let symbol = dlsym(image, "MacMultiplayerBindingsV1") else {
            dlclose(image)
            throw AppFailure("联机组件版本不兼容 / Incompatible Steamworks adapter")
        }
        self.image = image
        let get = unsafeBitCast(symbol, to: (@convention(c) () -> UnsafePointer<MPFunctions>).self)
        api = get().pointee
    }
    deinit {
        stop()
        dlclose(image)
    }

    func stop() {
        if initialized {
            api.stop()
            initialized = false
        }
    }

    func start() throws {
        if initialized { return }
        // Steam reads these during initialization. Keep game launch environments independent.
        let keys = ["SteamAppId", "SteamGameId"]
        let old = keys.map { key in getenv(key).map { String(cString: $0) } }
        for key in keys { setenv(key, "480", 1) }
        defer {
            for (key, previous) in zip(keys, old) {
                if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
            }
        }
        var error = [CChar](repeating: 0, count: 1024)
        guard api.start(&error, 1024) else { throw AppFailure(String(cString: error)) }
        initialized = true
    }

    struct Event {
        let info: MPEvent
        let data: Data
    }
    private final class Events { var values = [Event]() }
    func events() -> [Event] {
        let box = Events()
        api.poll(Unmanaged.passUnretained(box).toOpaque()) { context, info, bytes, n in
            let events = Unmanaged<Events>.fromOpaque(context!).takeUnretainedValue()
            events.values.append(Event(info: info, data: bytes.map { Data(bytes: $0, count: Int(n)) } ?? Data()))
        }
        return box.values
    }

    private final class Packets { var values = [(UInt64, Data)]() }
    func packets(connection: UInt32? = nil) -> [(UInt64, Data)] {
        let box = Packets()
        let context = Unmanaged.passUnretained(box).toOpaque()
        let sink: MPPacketSink = { context, peer, bytes, n in
            guard let bytes, n > 0, n <= 524288 else { return }
            Unmanaged<Packets>.fromOpaque(context!).takeUnretainedValue().values.append(
                (peer, Data(bytes: bytes, count: Int(n))))
        }
        if let connection { api.readTCP(connection, context, sink) } else { api.readVPN(context, sink) }
        return box.values
    }
    func name(_ id: UInt64) -> String { api.name(id).map(String.init(cString:)) ?? String(id) }
    func metadata(_ lobby: UInt64, _ key: String) -> String {
        api.metadata(lobby, key).map(String.init(cString:)) ?? ""
    }
}
