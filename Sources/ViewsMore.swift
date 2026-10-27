import AVFoundation
import AppKit
import SwiftUI

// MARK: Notes

struct NotesTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var notes: NotesStore

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Заметки").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { notes.newNote(); model.stayOpen() } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.icon).help("Новая заметка")
                }
                if notes.notes.isEmpty {
                    Text("Пока пусто").font(.system(size: 12)).foregroundStyle(faint).padding(.top, 4)
                }
                ListScroll {
                    VStack(spacing: 2) {
                        ForEach(notes.notes) { note in
                            row(note).transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(Motion.smooth, value: notes.notes.map(\.id))
                }
            }
            .padding(12)
            .frame(width: 200)
            .glass()
            .entrance(0)

            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { notes.current?.text ?? "" }, set: { notes.update(text: $0) }))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                if (notes.current?.text ?? "").isEmpty {
                    Text("Пишите — всё сохраняется само").font(.system(size: 13)).foregroundStyle(faint)
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .glass(tint: [Palette.yellow.opacity(0.08), .clear])
            .onTapGesture { model.stayOpen() }
            .entrance(1)
        }
    }

    private func row(_ note: NotesStore.Note) -> some View {
        let selected = note.id == notes.current?.id
        return VStack(alignment: .leading, spacing: 1) {
            Text(note.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
            Text(note.updated.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.clear)
                    .glass(tint: [Palette.yellow.opacity(0.25), Palette.orange.opacity(0.08)], radius: 9)
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
                    Caps(text: "Зеркало")
                    Text("Свет и кадр перед созвоном").font(.system(size: 15, weight: .semibold))
                    Text("Камера работает, только пока открыта эта вкладка. Ничего не записывается и не отправляется.")
                        .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Circle().fill(camera.state == .running ? Palette.green : faint).frame(width: 7, height: 7)
                        Text(camera.state == .running ? "Камера включена" : "Камера выключена")
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
                stat("Ёмкость", battery.health.map { "\($0)%" } ?? "—")
                stat("Циклы", battery.cycles.map(String.init) ?? "—")
                stat("Энергосбережение", ProcessInfo.processInfo.isLowPowerModeEnabled ? "вкл" : "выкл")
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
