import AppKit
import CoreLocation
import IOBluetooth

/// Headphones island: AirPods / Beats / any headset that connects, with battery levels when macOS knows them.
final class AudioDevices: NSObject, ObservableObject {
    private var connectNote: IOBluetoothUserNotification?
    private var onIsland: ((Island) -> Void)?
    private var lastShown: [String: Date] = [:]

    func start(onIsland: @escaping (Island) -> Void) {
        self.onIsland = onIsland
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? "Наушники"
        let lower = name.lowercased()
        let isAudio = device.deviceClassMajor == kBluetoothDeviceClassMajorAudio
        guard isAudio || lower.contains("airpods") || lower.contains("beats") else { return }
        // A reconnect within a minute is the same moment; do not repeat the island.
        if let last = lastShown[name], Date().timeIntervalSince(last) < 60 { return }
        lastShown[name] = Date()
        // Battery levels show up in system_profiler a moment after the connection.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.5) { [weak self] in
            let levels = Self.batteryLevels(for: name)
            DispatchQueue.main.async {
                self?.onIsland?(Island(kind: .airpods(name: name, levels: levels), seconds: 6))
            }
        }
    }

    private static func batteryLevels(for name: String) -> [String: Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.environment = AgentHub.childEnvironment
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        for section in sections {
            for key in ["device_connected", "device_title"] {
                for entry in section[key] as? [[String: Any]] ?? [] {
                    guard let info = entry[name] as? [String: Any] else { continue }
                    var levels: [String: Int] = [:]
                    let map = ["device_batteryLevelLeft": "L", "device_batteryLevelRight": "R",
                               "device_batteryLevelCase": "Кейс", "device_batteryLevelMain": "Заряд"]
                    for (k, label) in map {
                        if let s = info[k] as? String, let v = Int(s.filter(\.isNumber)) { levels[label] = v }
                    }
                    return levels
                }
            }
        }
        return [:]
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
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] marks, _ in
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
        case 0: return "Ясно"
        case 1, 2: return "Переменная облачность"
        case 3: return "Пасмурно"
        case 45, 48: return "Туман"
        case 51...57: return "Морось"
        case 61...67: return "Дождь"
        case 80...82: return "Ливень"
        case 71...77, 85, 86: return "Снег"
        case 95...99: return "Гроза"
        default: return ""
        }
    }
}
