import AppKit
import AVFoundation
import CoreAudio
import SwiftUI

extension Settings {
    private static var defaults: UserDefaults { .standard }

    static var dictation: Bool {
        get { defaults.bool(forKey: "dictation") }
        set { defaults.set(newValue, forKey: "dictation") }
    }
    /// One modifier key alone (watched by an event tap) or a combination / F-key (a Carbon hot key).
    static var dictationShortcut: Shortcut {
        get {
            if let code = defaults.object(forKey: "dictationKeyCode") as? Int,
               let modifiers = defaults.object(forKey: "dictationModifiers") as? Int {
                return Shortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers))
            }
            // The first version stored one of five presets by name.
            let code: UInt32? = switch defaults.string(forKey: "dictationKey") {
            case "rightCommand": 54
            case "rightControl": 62
            case "rightShift": 60
            case "fn": 63
            default: nil
            }
            return code.map { Shortcut(keyCode: $0, modifiers: 0) } ?? .dictation
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: "dictationKeyCode")
            defaults.set(Int(newValue.modifiers), forKey: "dictationModifiers")
            defaults.removeObject(forKey: "dictationKey")
        }
    }
    static var dictationMode: Dictation.Mode {
        get { Dictation.Mode(rawValue: defaults.string(forKey: "dictationMode") ?? "") ?? .hold }
        set { defaults.set(newValue.rawValue, forKey: "dictationMode") }
    }
    static var dictationModel: ParakeetModel {
        get { ParakeetModel(rawValue: defaults.string(forKey: "dictationModel") ?? "") ?? .ultra }
        set { defaults.set(newValue.rawValue, forKey: "dictationModel") }
    }
    /// A system sound by name (`/System/Library/Sounds`), "" for none. The first version had one switch for both.
    static var dictationStartSound: String {
        get { defaults.string(forKey: "dictationStartSound") ?? (oldSoundsSwitch ? "Tink" : "") }
        set { defaults.set(newValue, forKey: "dictationStartSound") }
    }
    static var dictationEndSound: String {
        get { defaults.string(forKey: "dictationEndSound") ?? (oldSoundsSwitch ? "Pop" : "") }
        set { defaults.set(newValue, forKey: "dictationEndSound") }
    }
    private static var oldSoundsSwitch: Bool { defaults.object(forKey: "dictationSounds") as? Bool ?? true }
    /// Insert into the app in front; off: only copy the text.
    static var dictationPaste: Bool {
        get { defaults.object(forKey: "dictationPaste") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dictationPaste") }
    }
    /// First letter and space fitted to the text before the cursor.
    static var dictationSmartCase: Bool {
        get { defaults.object(forKey: "dictationSmartCase") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dictationSmartCase") }
    }
    /// Core Audio UID of the microphone; nil follows the system's input device.
    static var dictationMicrophone: String? {
        get { defaults.string(forKey: "dictationMicrophone") }
        set { defaults.set(newValue, forKey: "dictationMicrophone") }
    }
    /// The model leaves memory after this many idle minutes; 0 keeps it.
    static var dictationUnloadMinutes: Int {
        get { defaults.object(forKey: "dictationUnloadMinutes") as? Int ?? 15 }
        set { defaults.set(newValue, forKey: "dictationUnloadMinutes") }
    }
}

/// Dictation from the notch: hold a modifier key (or tap it twice), speak, let go; the text goes into the app in
/// front. Recognition runs on this Mac (`ParakeetEngine`); the audio is never saved or sent anywhere.
final class Dictation: ObservableObject {
    enum Phase: Equatable { case idle, recording, transcribing }

    enum Mode: String, CaseIterable, Identifiable {
        case hold, toggle
        var id: String { rawValue }
        /// A modifier alone starts on a double tap (a single tap happens by accident); a combination on one press.
        func title(for shortcut: Shortcut) -> String {
            switch self {
            case .hold: "Удерживать, чтобы говорить"
            case .toggle: shortcut.isModifierOnly ? "Двойное нажатие — начать" : "Нажатие — начать и закончить"
            }
        }
    }

    struct Download: Equatable {
        var model: ParakeetModel
        var done: Int64
        var total: Int64
        /// The model is downloaded and is being prepared for the Neural Engine (first time: about 10 s).
        var preparing = false
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var download: Download?
    @Published private(set) var downloadError: String?
    /// The recorded combination is held by another app.
    @Published private(set) var shortcutTaken = false
    /// While Settings records a new shortcut: the old one does nothing.
    var paused = false { didSet { apply() } }
    /// Bumped when a model is installed or deleted, so views read `isInstalled` again.
    @Published private(set) var installs = 0
    /// Recording, recognising or putting the clipboard back: no restart for an update now.
    var isBusy: Bool { phase != .idle || TextInsertion.restoring }

    /// On the main thread: something to tell the person; `settings` adds a button to the Dictation settings.
    var onNotice: ((_ title: String, _ detail: String, _ settings: Bool) -> Void)?
    /// The level meter in the notch: 0…1, about 12 times a second while recording.
    var onLevel: ((Float) -> Void)?

    /// The engine lives here; loading and recognition never run on the main thread.
    private let queue = DispatchQueue(label: "nook.dictation", qos: .userInitiated)
    private var engine: ParakeetEngine?
    private var engineModel: ParakeetModel?
    private var unloadWork: DispatchWorkItem?
    private var downloader: ParakeetDownload?

    private var audio: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var target: NSRunningApplication?
    private var limit: Timer?

    private var watch: CFMachPort?
    private var watchSource: CFRunLoopSource?
    private var keys: CFMachPort?
    private var keysSource: CFRunLoopSource?
    private var keyDownAt: Date?
    private var chord = false
    private var lastTap: Date?
    private var holdWork: DispatchWorkItem?

    static let maxSeconds: TimeInterval = 300

    func start() { apply() }

    /// After a settings change: watch the key or stop watching, drop the model when dictation is off.
    func apply() {
        let on = Settings.dictation && !paused
        let shortcut = Settings.dictationShortcut
        if on && shortcut.isModifierOnly && AXIsProcessTrusted() { installWatch() } else { removeWatch() }
        HotKey.unregister(id: 3)
        comboDown = false
        var taken = false
        if on && !shortcut.isModifierOnly {
            taken = !HotKey.register(id: 3, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                                     onRelease: { [weak self] in self?.comboReleased() }) { [weak self] in self?.comboPressed() }
        }
        if shortcutTaken != taken { shortcutTaken = taken }
        if !Settings.dictation {
            cancel()
            unload()
        }
    }

    // MARK: Key

    /// Listen-only: typing never waits for Nook. Needs Accessibility.
    private func installWatch() {
        guard watch == nil else { return }
        let mask = (CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let dictation = Unmanaged<Dictation>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = dictation.watch { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                dictation.handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            // Without Accessibility trust a listening tap needs Input Monitoring instead.
            CGRequestListenEventAccess()
            onNotice?("Nook не слышит клавишу", "Разрешите Nook «Мониторинг ввода» в Системных настройках", true)
            return
        }
        watch = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        watchSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func removeWatch() {
        if let watch { CGEvent.tapEnable(tap: watch, enable: false); CFMachPortInvalidate(watch) }
        if let watchSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), watchSource, .commonModes) }
        watch = nil
        watchSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        let shortcut = Settings.dictationShortcut
        guard let mask = shortcut.modifierMask else { return }
        if type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == Int64(shortcut.keyCode) {
            if event.flags.rawValue & mask != 0 { pressed() } else { released() }
        } else if keyDownAt != nil {
            // ⌥ + a letter, or another modifier with it: a shortcut, not dictation (⌥L is "@" on a German
            // keyboard). Also after a slow start: the recording that began is dropped.
            chord = true
            holdWork?.cancel()
            if Settings.dictationMode == .hold && phase == .recording { cancel() }
        }
    }

    private func pressed() {
        keyDownAt = Date()
        chord = false
        guard Settings.dictationMode == .hold, phase == .idle else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.keyDownAt != nil, !self.chord else { return }
            self.begin()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func released() {
        let downAt = keyDownAt
        keyDownAt = nil
        holdWork?.cancel()
        switch Settings.dictationMode {
        case .hold:
            if phase == .recording { finish() }
        case .toggle:
            guard let downAt, !chord, Date().timeIntervalSince(downAt) < 0.3 else { lastTap = nil; return }
            if phase == .recording { finish(); lastTap = nil; return }
            if let lastTap, Date().timeIntervalSince(lastTap) < 0.4 {
                self.lastTap = nil
                begin()
            } else {
                lastTap = Date()
            }
        }
    }

    /// A combination or F-key: deliberate, so it starts at once (no 0.25 s wait as for a modifier alone).
    private var comboDown = false

    private func comboPressed() {
        guard !comboDown else { return }
        comboDown = true
        switch Settings.dictationMode {
        case .hold: if phase == .idle { begin() }
        case .toggle: phase == .recording ? finish() : begin()
        }
    }

    private func comboReleased() {
        comboDown = false
        if Settings.dictationMode == .hold && phase == .recording { finish() }
    }

    /// Return finishes and Escape cancels while recording; both are kept from the app in front.
    private func installKeys() {
        guard keys == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let dictation = Unmanaged<Dictation>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = dictation.keys { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 36, 76: DispatchQueue.main.async { dictation.finish() }
            case 53: DispatchQueue.main.async { dictation.cancel() }
            default: return Unmanaged.passUnretained(event)
            }
            return nil
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        keys = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        keysSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func removeKeys() {
        if let keys { CGEvent.tapEnable(tap: keys, enable: false); CFMachPortInvalidate(keys) }
        if let keysSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keysSource, .commonModes) }
        keys = nil
        keysSource = nil
    }

    // MARK: Recording

    func toggle() { phase == .recording ? finish() : begin() }

    func begin() {
        guard phase == .idle else { return }
        guard Settings.dictation else {
            onNotice?("Диктовка выключена", "Включите её: Настройки Nook → Диктовка", true)
            return
        }
        let model = Settings.dictationModel
        guard model.isInstalled else {
            onNotice?("Модель не скачана", "Скачайте её: Настройки Nook → Диктовка", true)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            // macOS asks once; the next press records.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            onNotice?("Нет доступа к микрофону", "Разрешите микрофон для Nook в Системных настройках", true)
            return
        }
        target = NSWorkspace.shared.frontmostApplication
        do {
            try startAudio()
        } catch {
            onNotice?("Микрофон не включился", error.localizedDescription, false)
            return
        }
        phase = .recording
        startedAt = Date()
        Self.play(Settings.dictationStartSound)
        installKeys()
        limit = Timer.scheduledTimer(withTimeInterval: Self.maxSeconds, repeats: false) { [weak self] _ in self?.finish() }
        // Loads while the person speaks: the first words are not waiting for the model.
        preload()
    }

    func finish() {
        guard phase == .recording else { return }
        stopAudio()
        let audio = lock.withLock { samples }
        lock.withLock { samples = [] }
        guard audio.count > ParakeetEngine.sampleRate / 3 else { phase = .idle; return }
        phase = .transcribing
        Self.play(Settings.dictationEndSound)
        let model = Settings.dictationModel
        let target = self.target
        queue.async { [weak self] in
            guard let self else { return }
            let context = Settings.dictationSmartCase ? Self.textBeforeCursor() : nil
            let result = Result { try self.engine(for: model).transcribe(audio) }
            DispatchQueue.main.async {
                self.phase = .idle
                switch result {
                case .success(let text):
                    let fitted = Self.fit(text, after: context)
                    if fitted.isEmpty {
                        self.onNotice?("Речь не распознана", "Говорите ближе к микрофону или громче", false)
                    } else {
                        self.insert(fitted, into: target)
                    }
                case .failure(let error):
                    self.onNotice?("Не удалось распознать речь", error.localizedDescription, false)
                }
                self.scheduleUnload()
            }
        }
    }

    func cancel() {
        guard phase == .recording else { return }
        stopAudio()
        lock.withLock { samples = [] }
        phase = .idle
    }

    private func startAudio() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = Settings.dictationMicrophone, var device = Self.deviceID(uid), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ParakeetEngine.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw ParakeetError.model("Нет входа звука.")
        }
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer, converter: converter, format: target)
        }
        engine.prepare()
        try engine.start()
        audio = engine
    }

    private func stopAudio() {
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
        removeKeys()
        limit?.invalidate()
        limit = nil
        startedAt = nil
    }

    /// On the audio thread: 16 kHz mono, plus a level for the meter.
    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, format: AVAudioFormat) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            // `.noDataNow`, not end of stream: the resampler keeps its state between buffers.
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard let data = output.floatChannelData?[0], output.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(output.frameLength))
        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let level = min(1, sqrt(sqrt(sum / Float(chunk.count))) * 2.2)
        lock.withLock {
            guard samples.count < Int(Self.maxSeconds) * ParakeetEngine.sampleRate else { return }
            samples.append(contentsOf: chunk)
        }
        DispatchQueue.main.async { self.onLevel?(level) }
    }

    // MARK: Text

    /// Through the clipboard and ⌘V (works in every app); the clipboard gets its content back afterwards.
    /// Marked transient, so clipboard managers (Nook's history too) skip it (`TextInsertion`).
    private func insert(_ text: String, into target: NSRunningApplication?) {
        let board = NSPasteboard.general
        guard Settings.dictationPaste else {
            board.clearContents()
            board.setString(text, forType: .string)
            onNotice?("Текст скопирован", "Вставьте его: ⌘V", false)
            return
        }
        TextInsertion.paste(text, into: target)
    }

    /// Up to three characters before the cursor in the focused text field (Accessibility); nil if unknown.
    /// Never logged or kept.
    private static func textBeforeCursor() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range) else { return nil }
        if range.location <= 0 { return "" }
        var before = CFRange(location: max(0, range.location - 3), length: min(3, range.location))
        guard let parameter = AXValueCreate(.cfRange, &before) else { return nil }
        var text: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                      parameter, &text) == .success, let text = text as? String {
            return text
        }
        return nil
    }

    /// After ". " or in an empty field: a capital; right after a word: a space before the text.
    /// A capital is never lowered mid-sentence: German nouns and English "I" keep theirs.
    static func fit(_ raw: String, after context: String?) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let context, let first = text.first else { return text }
        let before = context.trimmingCharacters(in: .whitespaces)
        let sentenceStart = before.isEmpty || before.last.map { ".!?…\n".contains($0) } == true
        if sentenceStart, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        if let last = context.last, !last.isWhitespace, !"([{«„\"'/".contains(last) { text = " " + text }
        return text
    }

    // MARK: Model

    /// On `queue`.
    private func engine(for model: ParakeetModel) throws -> ParakeetEngine {
        if let engine, engineModel == model { return engine }
        engine = nil
        let loaded = try ParakeetEngine(directory: model.directory)
        engine = loaded
        engineModel = model
        return loaded
    }

    func preload(then done: (() -> Void)? = nil) {
        unloadWork?.cancel()
        let model = Settings.dictationModel
        guard model.isInstalled else { done?(); return }
        queue.async { [weak self] in
            _ = try? self?.engine(for: model)
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    private func scheduleUnload() {
        unloadWork?.cancel()
        let minutes = Settings.dictationUnloadMinutes
        guard minutes > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.unload() }
        unloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes * 60), execute: work)
    }

    func unload() {
        unloadWork?.cancel()
        queue.async { [weak self] in
            self?.engine = nil
            self?.engineModel = nil
        }
    }

    func startDownload(_ model: ParakeetModel) {
        guard download == nil else { return }
        downloadError = nil
        let job = ParakeetDownload(model: model)
        // Progress queued just before "Отмена" must not bring the cancelled download back.
        job.onProgress = { [weak self, weak job] done, total in
            guard let self, let job, self.downloader === job else { return }
            self.download = Download(model: model, done: done, total: total)
        }
        job.onFinish = { [weak self, weak job] error in
            guard let self, let job, self.downloader === job else { return }
            self.downloader = nil
            if let error {
                self.download = nil
                self.downloadError = error.localizedDescription
                return
            }
            self.installs += 1
            // The first load compiles the model for this Mac; do it now, not on the first press.
            self.download?.preparing = true
            if Settings.dictationModel == model {
                self.preload { self.download = nil }
            } else {
                self.download = nil
            }
        }
        downloader = job
        download = Download(model: model, done: 0, total: model.downloadSize)
        job.start()
    }

    func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        download = nil
    }

    func delete(_ model: ParakeetModel) {
        if engineModel == model || Settings.dictationModel == model { unload() }
        queue.async { [weak self] in
            try? FileManager.default.removeItem(at: model.directory)
            DispatchQueue.main.async { self?.installs += 1 }
        }
    }

    // MARK: Sounds

    /// The system's alert sounds, by name.
    static let sounds: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()

    private static var playing: NSSound?

    /// One sound at a time: picking sounds one after another in Settings does not pile them up.
    static func play(_ name: String) {
        playing?.stop()
        playing = name.isEmpty ? nil : NSSound(named: NSSound.Name(name))
        playing?.play()
    }

    // MARK: Microphones

    struct Microphone: Identifiable, Hashable {
        var id: String
        var name: String
    }

    static var microphones: [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }

    private static func deviceID(_ uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}

/// Bars that follow the microphone level, drawn by Core Animation (no SwiftUI redraw per level).
struct LevelMeter: NSViewRepresentable {
    let dictation: Dictation
    var color: NSColor
    var bars = 7

    func makeNSView(context: Context) -> Host {
        let host = Host(color: color, bars: bars)
        dictation.onLevel = { [weak host] level in host?.push(level) }
        return host
    }

    func updateNSView(_ view: Host, context: Context) {}

    final class Host: NSView {
        private var bars: [CALayer] = []
        private var history: [Float]

        init(color: NSColor, bars count: Int) {
            history = [Float](repeating: 0, count: count)
            super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 16))
            wantsLayer = true
            for _ in history {
                let bar = CALayer()
                bar.backgroundColor = color.cgColor
                bar.cornerRadius = 1.5
                layer?.addSublayer(bar)
                bars.append(bar)
            }
        }
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            draw(animated: false)
        }

        func push(_ level: Float) {
            history.removeFirst()
            history.append(level)
            draw(animated: !Motion.reduce)
        }

        private func draw(animated: Bool) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(animated ? 0.08 : 0)
            CATransaction.setDisableActions(!animated)
            let gap = bounds.width / CGFloat(bars.count)
            for (i, bar) in bars.enumerated() {
                let height = max(3, bounds.height * CGFloat(history[i]))
                bar.frame = CGRect(x: CGFloat(i) * gap + (gap - 3) / 2, y: (bounds.height - height) / 2, width: 3, height: height)
            }
            CATransaction.commit()
        }
    }
}
