import AppKit
import AVFoundation

/// Quick notes in the notch: plain text, saved while you type (owner-only file).
final class NotesStore: ObservableObject {
    struct Note: Codable, Identifiable, Equatable {
        var id = UUID()
        var text = ""
        var updated = Date()

        var title: String {
            let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return line.map { String($0.trimmingCharacters(in: .whitespaces).prefix(60)) } ?? "Новая заметка"
        }
    }

    @Published private(set) var notes: [Note] = []
    @Published var currentID: UUID?

    private let url = supportDir.appendingPathComponent("notes.json")
    private let io = DispatchQueue(label: "nook.notes")
    private var saveWork: DispatchWorkItem?

    var current: Note? { notes.first { $0.id == currentID } ?? notes.first }

    func start() {
        io.async { [weak self] in
            guard let self, let data = try? Data(contentsOf: self.url),
                  let saved = try? JSONDecoder().decode([Note].self, from: data) else { return }
            DispatchQueue.main.async {
                self.notes = saved
                if self.currentID == nil { self.currentID = saved.first?.id }
            }
        }
    }

    func newNote() {
        // An empty note at the top is reused instead of piling up blanks.
        if let blank = notes.first, blank.text.isEmpty { currentID = blank.id; return }
        let note = Note()
        notes.insert(note, at: 0)
        currentID = note.id
        save()
    }

    func update(text: String) {
        if current == nil { newNote() }
        guard let id = current?.id, let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].updated = Date()
        save()
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        if currentID == note.id { currentID = notes.first?.id }
        save()
    }

    func copy(_ note: Note) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
    }

    /// Debounced write on a background queue.
    private func save() {
        saveWork?.cancel()
        let snapshot = notes, url = url
        let work = DispatchWorkItem { [weak self] in
            self?.io.async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

/// The built-in camera as a mirror. Runs only while the Mirror tab is open; nothing is recorded.
final class MirrorCamera: ObservableObject {
    enum State { case idle, running, denied, unavailable }

    @Published private(set) var state: State = .idle
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "nook.mirror")
    private var configured = false
    private var wanted = false

    func start() {
        wanted = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.run() : (self.state = .denied) }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        wanted = false
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
        if state == .running { state = .idle }
    }

    /// startRunning blocks for a moment, so it runs on the camera queue.
    private func run() {
        queue.async { [weak self] in
            guard let self, self.wanted else { return }
            if !self.configured { self.configured = self.configure() }
            guard self.configured else {
                DispatchQueue.main.async { self.state = .unavailable }
                return
            }
            self.session.startRunning()
            DispatchQueue.main.async { if self.wanted { self.state = .running } }
        }
    }

    private func configure() -> Bool {
        // Prefer the built-in camera over an iPhone offered through Continuity.
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
                                                       position: .unspecified).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)
        session.commitConfiguration()
        return true
    }
}
