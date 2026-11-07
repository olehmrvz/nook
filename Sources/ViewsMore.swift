import AVFoundation
import AppKit
import SwiftUI

// MARK: Notes

/// Figma «H · Заметки»: notes as tiles, a new one at the end; the open note in the editor on the right.
struct NotesTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var notes: NotesStore

    var body: some View {
        GeometryReader { geo in
            let col = (geo.size.width - 3 * Spacing.gap) / 4
            let row = (geo.size.height - Spacing.gap) / 2
            HStack(alignment: .top, spacing: Spacing.gap) {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.fixed(col), spacing: Spacing.gap), GridItem(.fixed(col), spacing: Spacing.gap)],
                              spacing: Spacing.gap) {
                        ForEach(notes.notes) { note in
                            tile(note).frame(height: row).transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        newTile.frame(height: row)
                    }
                    .animation(Motion.smooth, value: notes.notes.map(\.id))
                }
                .defaultScrollAnchor(.top)
                .frame(width: 2 * col + Spacing.gap)
                .entrance(0)
                editor.entrance(1)
            }
        }
    }

    private func tile(_ note: NotesStore.Note) -> some View {
        let selected = note.id == notes.current?.id
        let body = note.text.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        return Tile(kind: selected ? .selected : .plain) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title.isEmpty ? L("Без названия") : note.title).font(.system(size: 13, weight: .bold)).lineLimit(2)
                if !body.isEmpty {
                    Text(body).font(.system(size: 11)).foregroundStyle(muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(Self.when(note.updated)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.quick) { notes.currentID = note.id } }
        .contextMenu {
            Button("Скопировать текст") { notes.copy(note) }
            Divider()
            Button("Удалить") { withAnimation(Motion.smooth) { notes.delete(note) } }
        }
    }

    private var newTile: some View {
        Button { notes.newNote(); model.stayOpen() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                Text("Новая заметка").font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tile(.target(Tone.ink))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle())
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { notes.current?.text ?? "" }, set: { notes.update(text: $0) }))
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, -5)
                if (notes.current?.text ?? "").isEmpty {
                    Text("Пишите — всё сохраняется само").font(.system(size: 13)).foregroundStyle(faint)
                        .allowsHitTesting(false)
                }
            }
            if let note = notes.current {
                HStack {
                    Text(L("сохранено · ") + note.updated.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Text("Пишите — всё сохраняется само").font(.system(size: 11)).foregroundStyle(muted)
                }
                .padding(.top, 8)
            }
        }
        .padding(Spacing.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile()
        .onTapGesture { model.stayOpen() }
    }

    /// "сегодня · 18:04", "вчера · 21:10", "3 нояб.".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return L("сегодня · ") + time }
        if cal.isDateInYesterday(date) { return L("вчера · ") + time }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: Mirror

struct MirrorTab: View {
    @ObservedObject var camera: MirrorCamera

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Color.black
                switch camera.state {
                case .running:
                    CameraPreview(session: camera.session)
                        .scaleEffect(x: -1, y: 1)
                        .transition(.opacity)
                case .denied:
                    VStack(spacing: 8) {
                        Badge(symbol: "video.slash.fill", colors: [Palette.red, Palette.orange], size: 44)
                        Text("Нет доступа к камере").font(.system(size: 14, weight: .semibold))
                        Button("Открыть настройки") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                        }
                        .buttonStyle(.pill(.primary, small: true))
                    }
                case .unavailable:
                    VStack(spacing: 8) {
                        Badge(symbol: "video.slash", colors: [Palette.violet, Palette.blue], size: 44)
                        Text("Камера не найдена").font(.system(size: 14, weight: .semibold))
                    }
                case .idle:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 448, height: 252)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .animation(Motion.smooth, value: camera.state)
            .entrance(0)

            Card(tint: [Palette.cyan.opacity(0.12), .clear], padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Caps(text: L("Зеркало"))
                    Text("Свет и кадр перед созвоном").font(.system(size: 15, weight: .semibold))
                    Text("Камера работает, только пока открыта эта вкладка. Ничего не записывается и не отправляется.")
                        .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Circle().fill(camera.state == .running ? Palette.green : faint).frame(width: 7, height: 7)
                        Text(camera.state == .running ? L("Камера включена") : L("Камера выключена"))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                    }
                }
            }
            .entrance(1)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

/// AVCaptureVideoPreviewLayer in a layer-hosting view.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: Power

/// Battery details under the header chip, with the way to the macOS charge limit.
struct PowerCard: View {
    @ObservedObject var battery: Battery

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(battery.percent)%").font(.rounded(30)).contentTransition(.numericText())
                Text(battery.headline).font(.system(size: 12, weight: .semibold)).foregroundStyle(battery.tint)
                Spacer(minLength: 0)
            }
            GlowBar(fraction: Double(battery.percent) / 100,
                    colors: battery.percent <= 20 && !battery.pluggedIn ? [Palette.red, Palette.orange] : [Palette.green, Palette.mint],
                    height: 6)
            Text(battery.detail).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                stat(L("Ёмкость"), battery.health.map { "\($0)%" } ?? "—")
                stat(L("Циклы"), battery.cycles.map(String.init) ?? "—")
                stat(L("Энергосбережение"), ProcessInfo.processInfo.isLowPowerModeEnabled ? L("вкл") : L("выкл"))
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            Text("Лимит заряда 80–100 % задаётся в macOS и работает даже без Nook.")
                .font(.system(size: 11)).foregroundStyle(faint).fixedSize(horizontal: false, vertical: true)
            Button { Battery.openChargeLimitSettings() } label: {
                Label("Настроить лимит заряда", systemImage: "battery.75percent")
            }
            .buttonStyle(.pill(.primary, small: true))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(white: 0.07)))
        .glass(tint: [Palette.green.opacity(0.12), .clear], radius: 20)
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(faint)
            Text(value).font(.rounded(13))
        }
    }
}
