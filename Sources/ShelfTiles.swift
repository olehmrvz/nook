import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Shelf (Figma «H · Полка»: file tiles, then where to drop and what to do with all of them)

struct ShelfTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: Shelf
    @State private var targeted = false

    private static let tileHeight: CGFloat = 126

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.gap), count: 4), spacing: Spacing.gap) {
                ForEach(shelf.items) { item in
                    ShelfTile(item: item, shelf: shelf) { ok in model.show(ok ? .copied : .noText, for: 1.6) }
                        .frame(height: Self.tileHeight)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                dropTile.frame(height: Self.tileHeight)
                if !shelf.items.isEmpty { summaryTile.frame(height: Self.tileHeight) }
            }
            .animation(Motion.smooth, value: shelf.items.map(\.id))
        }
        .defaultScrollAnchor(.top)
        // While a file is dragged, the whole shelf is the target: the drop tile at the end can be scrolled away.
        .overlay {
            if model.draggingFile || targeted { dropZone.transition(.opacity) }
        }
        .animation(Motion.quick, value: model.draggingFile || targeted)
        .entrance(0)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { shelf.add([url]) } }
                }
            }
            return true
        }
    }

    private var dropTile: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(Tone.limit)
            Text(shelf.items.isEmpty ? L("Перетащите файлы на вырез") : L("Перетащите файлы\nна вырез"))
                .font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center)
            if shelf.items.isEmpty {
                Text("Новые скриншоты попадают сюда сами").font(.system(size: 11)).foregroundStyle(muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tile(.target(Tone.limit))
        .brightness(targeted ? 0.12 : 0)
        .animation(Motion.quick, value: targeted)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 28, weight: .semibold)).foregroundStyle(Tone.limit)
            Text("Отпустите — файл ляжет на полку первым").font(.system(size: 15, weight: .semibold))
            Text("Он остаётся на своём месте; на полке — ссылка на него").font(.system(size: 11.5)).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous).fill(Color.black.opacity(0.82)))
        .tile(.target(Tone.limit))
        .brightness(targeted ? 0.06 : 0)
        .allowsHitTesting(false)
    }

    private var summaryTile: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(shelf.items.count)").font(.rounded(30, .heavy)).contentTransition(.numericText())
                Text(Format.count(shelf.items.count, "файл", "файла", "файлов").drop { $0 != " " }.dropFirst() + L(" на полке"))
                    .font(.system(size: 12, weight: .semibold)).padding(.top, 2)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button("AirDrop") { shelf.airDrop(shelf.items.map(\.url)) }.buttonStyle(.pill(.ghost, small: true))
                    ConfirmButton(confirm: L("Точно?"), action: shelf.clear) {
                        Text("Очистить").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).frame(height: 24)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain).focusable(false)
                    .help("Убрать всё с полки (файлы остаются на месте): нажмите дважды")
                }
            }
        }
        .help("Перетащите файл наружу, чтобы использовать его")
    }
}

/// An icon by file type, never read from the file: a path in Documents or on a network volume that is gone could
/// ask for a permission or stall, and views draw on the main thread.
enum FileIcon {
    static func byType(_ path: String) -> NSImage {
        let ext = (path as NSString).pathExtension
        let type = ext.isEmpty ? UTType.folder : (UTType(filenameExtension: ext) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }
}

/// One file: thumbnail, name and type; when it came; AirDrop and remove on hover. Drag it out to use it.
struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: Shelf
    /// Feedback after "copy text": true when some text was found.
    var copiedText: (Bool) -> Void = { _ in }
    @State private var hover = false

    var body: some View {
        Tile(kind: hover ? .selected : .plain) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(3).truncationMode(.middle)
                        Text(kind).font(.system(size: 10.5)).foregroundStyle(muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(Self.when(item.added)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                    tileButton("airplayaudio", help: L("AirDrop")) { shelf.airDrop([item.url]) }
                    tileButton("xmark", help: L("Убрать с полки")) { shelf.remove(item) }
                }
            }
        }
        .animation(Motion.quick, value: hover)
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { shelf.open(item) }
        .contextMenu {
            Button("Открыть") { shelf.open(item) }
            Button("Скопировать") { shelf.copy(item) }
            if UTType(filenameExtension: item.url.pathExtension)?.conforms(to: .image) == true {
                Button("Скопировать текст с картинки") { TextRecognizer.copyText(from: item.url, done: copiedText) }
            }
            Button("Показать в Finder") { shelf.reveal(item) }
            Button("AirDrop") { shelf.airDrop([item.url]) }
            Divider()
            Button("Убрать с полки") { shelf.remove(item) }
        }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .help(item.path)
    }

    private var thumbnail: some View {
        Group {
            if let image = shelf.thumbnails[item.path] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(nsImage: FileIcon.byType(item.path)).resizable().scaledToFit().padding(3)
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The file's type in words: "PNG", "Папка".
    private var kind: String {
        let ext = item.url.pathExtension
        return ext.isEmpty ? L("Папка") : ext.uppercased()
    }

    /// "18:01", "вчера", "3 нояб.".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return L("вчера") }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func tileButton(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(hover ? 0.8 : 0.4))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.icon)
        .help(help)
    }
}
