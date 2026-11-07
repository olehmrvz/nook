import AppKit
import CoreAudio
import CoreLocation
import IOBluetooth

/// Headphones island: AirPods / Beats / any headset that connects, with battery levels when macOS knows them.
/// Apple headphones also drop out when automatic switching takes them to another device, with «Вернуть».
///
/// macOS's own grey banners for the same moments cannot be turned off: they come from the system bundle
/// com.apple.BTUserNotifications, which hides itself from System Settings → Notifications (`UNHideSettings`).
final class AudioDevices: NSObject, ObservableObject {
    private var connectNote: IOBluetoothUserNotification?
    private var onIsland: ((Island) -> Void)?
    /// By Bluetooth address ("08:65:18:6C:A0:98"), or by name for a device without one.
    private var lastShown: [String: Date] = [:]
    private let banners = HeadphoneBanners()
    /// «Вернуть» in progress: address → name; `confirmed` once macOS says they are connected here again.
    private var returning: [String: String] = [:]
    private var confirmed: Set<String> = []
    private var opening: [String: IOBluetoothDevice] = [:]
    /// CoreAudio waits, so the return runs here, off the main thread.
    private let queue = DispatchQueue(label: "nook.headphones")

    func start(onIsland: @escaping (Island) -> Void) {
        self.onIsland = onIsland
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        banners.onEvent = { [weak self] event in DispatchQueue.main.async { self?.handle(event) } }
        banners.start()
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? L("Наушники")
        let lower = name.lowercased()
        let isAudio = device.deviceClassMajor == kBluetoothDeviceClassMajorAudio
        guard isAudio || lower.contains("airpods") || lower.contains("beats") else { return }
        announce(address: device.addressString ?? name, name: name)
    }

    private func handle(_ event: HeadphoneBanners.Event) {
        switch event {
        case .connected(let name, let address):
            let key = Self.normalized(address)
            if returning[key] != nil { confirmed.insert(key) }
            announce(address: key, name: name)
        case .moved(let name, let address, let device, let seconds):
            // Coming back is news again, even within the minute.
            lastShown[Self.normalized(address)] = nil
            onIsland?(Island(kind: .airpodsAway(name: name, address: Self.normalized(address), device: device),
                             seconds: min(30, max(8, seconds))))
        }
    }

    /// The connected drop. A reconnect within a minute is the same moment; do not repeat the island.
    private func announce(address: String, name: String) {
        let key = Self.normalized(address)
        if let last = lastShown[key], Date().timeIntervalSince(last) < 60 { return }
        lastShown[key] = Date()
        // Battery levels show up in system_profiler a moment after the connection.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.5) { [weak self] in
            let found = Self.profile(address: key, name: name)
            DispatchQueue.main.async {
                self?.onIsland?(Island(kind: .airpods(name: found.name ?? name, levels: found.levels), seconds: 6))
            }
        }
    }

    // MARK: «Вернуть»

    /// Brings the headphones back to this Mac: opens the Bluetooth link if it dropped, then starts silent sound on
    /// them. Automatic switching moves AirPods to the device that starts playing; there is no public call for
    /// macOS's own "Подключить" button. The result is a drop: the headphones' own, or a notice that it failed.
    func bringBack(address: String, name: String) {
        let key = Self.normalized(address)
        guard returning[key] == nil else { return }
        returning[key] = name
        guard let device = IOBluetoothDevice(addressString: key) else { return finish(key, ok: false) }
        if device.isConnected() { return playHere(key) }
        // Asynchronous: `connectionComplete` comes on the main run loop, nothing waits here.
        opening[key] = device
        if device.openConnection(self) != kIOReturnSuccess {
            opening[key] = nil
            return finish(key, ok: false)
        }
        // A page attempt ends in seconds; never leave «Вернуть» stuck if the answer does not come.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.opening.removeValue(forKey: key) != nil { self?.finish(key, ok: false) }
        }
    }

    @objc(connectionComplete:status:) func connectionComplete(_ device: IOBluetoothDevice?, status: IOReturn) {
        let key = Self.normalized(device?.addressString ?? "")
        guard opening.removeValue(forKey: key) != nil else { return }
        if status == kIOReturnSuccess { playHere(key) } else { finish(key, ok: false) }
    }

    private func playHere(_ key: String) {
        queue.async { [weak self] in
            let ok = Self.playSilence(uid: Self.outputUID(key))
            DispatchQueue.main.async { self?.finish(key, ok: ok) }
        }
    }

    private func finish(_ key: String, ok: Bool) {
        guard let name = returning.removeValue(forKey: key) else { return }
        let seenByMacOS = confirmed.remove(key) != nil
        if ok || seenByMacOS {
            announce(address: key, name: name)
        } else {
            onIsland?(Island(kind: .notice(symbol: "headphones", title: L("Не удалось вернуть «\(name)»"),
                                           detail: L("Выберите их в Пункте управления → Bluetooth"), ok: false), seconds: 6))
        }
    }

    /// Runs on `queue`. 3 s of silence on the headphones' output (hidden while they are away, still found by its
    /// UID) and on the default output: macOS asks the headphones to come here when an app starts sound on either
    /// (seen in its log as "Routing request … Hijack"). True when they are this Mac's output afterwards.
    private static func playSilence(uid: String) -> Bool {
        let wasHere = isCurrentOutput(uid: uid)
        // Right after a new Bluetooth connection their device takes a moment to appear.
        var headphones = audioDevice(uid: uid)
        for _ in 0..<8 where headphones == nil {
            Thread.sleep(forTimeInterval: 0.25)
            headphones = audioDevice(uid: uid)
        }
        let silence: AudioDeviceIOBlock = { _, _, _, buffers, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        var playing: [(AudioObjectID, AudioDeviceIOProcID)] = []
        defer {
            for (device, proc) in playing {
                AudioDeviceStop(device, proc)
                AudioDeviceDestroyIOProcID(device, proc)
            }
        }
        for device in Set([headphones, defaultOutput()].compactMap { $0 }) {
            var proc: AudioDeviceIOProcID?
            guard AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil, silence) == noErr, let proc else { continue }
            if AudioDeviceStart(device, proc) == noErr { playing.append((device, proc)) } else { AudioDeviceDestroyIOProcID(device, proc) }
        }
        guard !playing.isEmpty else { return false }
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            if !wasHere && isCurrentOutput(uid: uid) { return true }
        }
        // Looking like the output at the start is not enough: for 2 s after a switch macOS still lists them so.
        return isCurrentOutput(uid: uid)
    }

    private static func isCurrentOutput(uid: String) -> Bool {
        guard let device = audioDevice(uid: uid) else { return false }
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &hidden) == noErr, hidden == 0 else { return false }
        return defaultOutput() == device
    }

    /// Also finds a hidden device, which the device list leaves out.
    private static func audioDevice(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func defaultOutput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    // MARK: Words

    /// "08-65-18-6c-a0-98" (IOBluetooth) and "08:65:18:6C:A0:98" (system_profiler, the log) as one key.
    static func normalized(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    /// The output device of Bluetooth headphones: "08-65-18-6C-A0-98:output".
    private static func outputUID(_ key: String) -> String {
        key.replacingOccurrences(of: ":", with: "-") + ":output"
    }

    /// The name the user gave the headphones (IOBluetooth may still say "AirPods") and their battery levels,
    /// from system_profiler: by Bluetooth address, else by name.
    private static func profile(address: String, name: String) -> (name: String?, levels: [String: Int]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.environment = AgentHub.childEnvironment
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, [:]) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return (nil, [:]) }
        for section in sections {
            for key in ["device_connected", "device_title"] {
                for entry in section[key] as? [[String: Any]] ?? [] {
                    for (title, value) in entry {
                        guard let info = value as? [String: Any],
                              (info["device_address"] as? String).map(normalized) == address || title == name else { continue }
                        var levels: [String: Int] = [:]
                        let map = ["device_batteryLevelLeft": "L", "device_batteryLevelRight": "R",
                                   "device_batteryLevelCase": L("Кейс"), "device_batteryLevelMain": L("Заряд")]
                        for (k, label) in map {
                            if let s = info[k] as? String, let v = Int(s.filter(\.isNumber)) { levels[label] = v }
                        }
                        return (title, levels)
                    }
                }
            }
        }
        return (nil, [:])
    }
}

/// macOS's own headphone banners, read from the system log with `log stream`.
///
/// audioaccessoryd writes "PostingBanner: Type ReverseRoute, Name …, Addr …, …, Timeout 20.000" when automatic
/// switching takes AirPods to another device of the same Apple Account (macOS: "Переключились на iPhone ·
/// Подключить") and "PostingBanner: Type Connected, …" when they come (back) to this Mac; a metrics line with
/// "Hijack_Away" names the kind of the other device. Nothing else shows a switch: the Bluetooth link stays up (the
/// AirPods keep both devices), and macOS draws these banners itself without storing them in the Notification Center
/// database. The text is not an API (checked on macOS 27.2): if an update changes it, the drops stop; they never
/// come for a plain disconnect. Costs one sleeping `log` process; the system filters by process before sending.
final class HeadphoneBanners {
    enum Event {
        case connected(name: String, address: String)
        /// `device`: "iPhone", "iPad"… when macOS names it.
        case moved(name: String, address: String, device: String?, seconds: Double)
    }

    var onEvent: ((Event) -> Void)?
    private let queue = DispatchQueue(label: "nook.headphone-banners")
    private var process: Process?
    private var buffer = Data()
    private var away: (device: String, at: Date)?
    private var quickExits = 0
    private var stopped = false

    private static let predicate = #"process == "audioaccessoryd" AND (eventMessage BEGINSWITH "PostingBanner: Type " OR eventMessage CONTAINS "Hijack_Away")"#
    private static let banner = try! NSRegularExpression(pattern: #"^PostingBanner: Type (\w+), Name (.*), Addr ((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})"#)
    private static let timeout = try! NSRegularExpression(pattern: #"Timeout ([0-9.]+)"#)
    private static let otherDevice = try! NSRegularExpression(pattern: #""OtherTipiDeviceModel" : "([^"]+)""#)

    func start() {
        queue.async { self.launch(first: true) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.sync {
                self?.stopped = true
                self?.process?.terminate()
            }
        }
    }

    /// Runs on `queue`.
    private func launch(first: Bool) {
        guard !stopped else { return }
        // A Nook that was killed (install.sh) leaves its `log` behind until the next banner: end those first.
        if first { Self.run("/usr/bin/pkill", ["-P", "1", "-f", "^/usr/bin/log stream .*PostingBanner"]) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate", Self.predicate]
        process.environment = AgentHub.childEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.receive(data) }
        }
        let started = Date()
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.ended(after: Date().timeIntervalSince(started)) }
        }
        guard (try? process.run()) != nil else { return }
        self.process = process
    }

    /// Runs on `queue`. Restarts a stream that ended; one that keeps ending at once (`log stream` needs an admin
    /// account) is left alone until the next launch.
    private func ended(after seconds: TimeInterval) {
        process = nil
        buffer.removeAll()
        quickExits = seconds < 10 ? quickExits + 1 : 0
        guard !stopped, quickExits < 3 else { return }
        queue.asyncAfter(deadline: .now() + (quickExits == 0 ? 2 : 30)) { self.launch(first: false) }
    }

    /// Runs on `queue`.
    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<end])
            buffer = Data(buffer[buffer.index(after: end)...])
            // The first line is plain text ("Filtering the log data using …").
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object["eventMessage"] as? String else { continue }
            parse(message)
        }
        if buffer.count > 1 << 16 { buffer.removeAll() }
    }

    /// Runs on `queue` (not private: a scratch harness feeds it lines from `log show`).
    func parse(_ message: String) {
        if message.contains("Hijack_Away") {
            if let device = Self.capture(Self.otherDevice, message, 1), !["NA", "Unknown"].contains(device) { away = (device, Date()) }
            return
        }
        guard let type = Self.capture(Self.banner, message, 1), let name = Self.capture(Self.banner, message, 2),
              let address = Self.capture(Self.banner, message, 3) else { return }
        switch type {
        case "Connected":
            onEvent?(.connected(name: name, address: address))
        case "ReverseRoute":
            let seconds = Self.capture(Self.timeout, message, 1).flatMap(Double.init) ?? 20
            // The metrics line that names the other device comes a few milliseconds after the banner.
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let device = self.away.flatMap { Date().timeIntervalSince($0.at) < 3 ? $0.device : nil }
                self.onEvent?(.moved(name: name, address: address, device: device, seconds: seconds))
            }
        default:
            break
        }
    }

    private static func capture(_ regex: NSRegularExpression, _ text: String, _ group: Int) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}

/// Current weather from Open-Meteo (no key, no account). Location from Location Services,
/// or the city of the time zone when location is off.
final class Weather: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var temperature: Double?
    @Published private(set) var code = 0
    @Published private(set) var isDay = true
    @Published private(set) var high: Double?
    @Published private(set) var low: Double?
    @Published private(set) var place = ""

    private let manager = CLLocationManager()
    private var coordinate: CLLocationCoordinate2D?
    private var timer: Timer?

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.coordinate == nil { self?.fallbackToTimeZone() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [weak self] _ in
            self?.manager.requestLocation()
            self?.fetch()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let first = coordinate == nil
        coordinate = location.coordinate
        // The city name comes from Apple's servers: they get the same ~1 km as the weather, not the exact position.
        let rounded = CLLocation(latitude: (location.coordinate.latitude * 100).rounded() / 100,
                                 longitude: (location.coordinate.longitude * 100).rounded() / 100)
        CLGeocoder().reverseGeocodeLocation(rounded) { [weak self] marks, _ in
            if let city = marks?.first?.locality { DispatchQueue.main.async { self?.place = city } }
        }
        if first { fetch() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if coordinate == nil { fallbackToTimeZone() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.requestLocation()
    }

    private func fallbackToTimeZone() {
        let city = TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
        guard !city.isEmpty, coordinate == nil,
              let q = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?count=1&name=\(q)") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (root["results"] as? [[String: Any]])?.first,
                  let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else { return }
            DispatchQueue.main.async {
                guard self?.coordinate == nil else { return }
                self?.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                self?.place = first["name"] as? String ?? city
                self?.fetch()
            }
        }.resume()
    }

    func fetch() {
        guard let c = coordinate else { return }
        // About a kilometre is enough for weather; the exact position stays on the Mac.
        let lat = (c.latitude * 100).rounded() / 100, lon = (c.longitude * 100).rounded() / 100
        let s = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto"
        guard let url = URL(string: s) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = root["current"] as? [String: Any] else { return }
            let daily = root["daily"] as? [String: Any]
            DispatchQueue.main.async {
                self?.temperature = current["temperature_2m"] as? Double
                self?.code = current["weather_code"] as? Int ?? 0
                self?.isDay = (current["is_day"] as? Int ?? 1) == 1
                self?.high = (daily?["temperature_2m_max"] as? [Double])?.first
                self?.low = (daily?["temperature_2m_min"] as? [Double])?.first
            }
        }.resume()
    }

    var symbol: String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    var summary: String {
        switch code {
        case 0: return L("Ясно")
        case 1, 2: return L("Переменная облачность")
        case 3: return L("Пасмурно")
        case 45, 48: return L("Туман")
        case 51...57: return L("Морось")
        case 61...67: return L("Дождь")
        case 80...82: return L("Ливень")
        case 71...77, 85, 86: return L("Снег")
        case 95...99: return L("Гроза")
        default: return ""
        }
    }
}
