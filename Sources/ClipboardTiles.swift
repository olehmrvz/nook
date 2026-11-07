import AppKit
import SwiftUI

// MARK: Clipboard (Figma «H · Буфер»: tiles by type — link, text, picture, file, colour)

struct ClipboardTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: ClipboardStore
    @FocusState private var searchFocused: Bool

    private static let columns = 4
    private static let tileHeight: CGFloat = 104

    var body: some View {
        let items = store.filtered
        VStack(spacing: Spacing.gap) {
            searchRow(items).entrance(0)
            if items.isEmpty {
                Tile {
                    VStack(spacing: 8) {
                        TileIcon(symbol: store.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass", color: Tone.info, size: 40)
                        Text(store.query.isEmpty && store.filter == .all ? L("Скопируйте что-нибудь — оно появится здесь") : L("Ничего не найдено"))
                            .font(.system(size: 12)).foregroundStyle(muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .entrance(1)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.gap), count: Self.columns),
                                  spacing: Spacing.gap) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipTile(item: item, store: store, selected: index == store.selection) { model.pick(item) }
                                    .frame(height: Self.tileHeight)
                                    .contextMenu { menu(item) }
                                    .id(item.id)
                                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }
                        .animation(Motion.smooth, value: items.map(\.id))
                    }
                    .defaultScrollAnchor(.top)
                    .entrance(1)
                    .onChange(of: store.selection) { _, new in
                        if items.indices.contains(new) { withAnimation(Motion.quick) { proxy.scrollTo(items[new].id) } }
                    }
                }
            }
        }
        // Focus only when Nook owns the keyboard (opened with ⌃⌘V); otherwise typing stays in your app.
        .onAppear { if model.sticky && model.panel?.isKeyWindow == true { searchFocused = true } }
    }

    private func searchRow(_ items: [ClipItem]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(muted)
                TextField("Поиск в буфере", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { if items.indices.contains(store.selection) { model.pick(items[store.selection]) } }
                    // A grid: down and up move a row; left and right a tile while there is no text to edit.
                    .onKeyPress(.downArrow) { move(Self.columns, count: items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-Self.columns, count: items.count); return .handled }
                    .onKeyPress(.rightArrow) { guard store.query.isEmpty else { return .ignored }; move(1, count: items.count); return .handled }
                    .onKeyPress(.leftArrow) { guard store.query.isEmpty else { return .ignored }; move(-1, count: items.count); return .handled }
                    .onKeyPress(.escape) { model.collapse(); return .handled }
                    .onChange(of: store.query) { _, _ in store.selection = 0 }
                if AXIsProcessTrusted() {
                    Text("↩ вставить").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                } else {
                    // Without Accessibility, ↩ only copies; one click asks macOS for the permission.
                    Button("↩ копирует · включить вставку") {
                        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                    }
                    .buttonStyle(.icon).font(.system(size: 11)).foregroundStyle(faint)
                    .help("Разрешить Nook вставлять выбранное в предыдущее приложение (Универсальный доступ)")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.08))))
            if store.canUndo {
                Button("Вернуть") { store.undoRemove() }
                    .buttonStyle(.pill(.ghost, small: true)).focusable(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Menu {
                Picker("Показывать", selection: $store.filter) {
                    ForEach(ClipboardStore.Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                square(store.filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",
                       active: store.filter != .all)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().focusable(false)
            .help("Только текст, ссылки, картинки или файлы")
            .onChange(of: store.filter) { _, _ in store.selection = 0 }
            ConfirmButton(confirm: L("Очистить всё?"), action: store.clearUnpinned) { square("trash") }
                .buttonStyle(.icon).focusable(false)
                .help("Очистить всё, кроме закреплённого: нажмите дважды (можно вернуть 15 с)")
        }
        .animation(Motion.quick, value: store.canUndo)
    }

    private func square(_ symbol: String, active: Bool = false) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? Tone.info : .white.opacity(0.7))
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder private func menu(_ item: ClipItem) -> some View {
        Button(model.sticky && AXIsProcessTrusted() ? L("Вставить") : L("Скопировать")) { model.pick(item) }
        if let url = store.imageURL(for: item) {
            Button("Скопировать текст с картинки") {
                TextRecognizer.copyText(from: url) { ok in model.show(ok ? .copied : .noText, for: 1.6) }
            }
        }
        Button(item.pinned ? L("Открепить") : L("Закрепить")) { store.togglePin(item) }
        Divider()
        Button("Удалить") { store.delete(item, source: "menu") }
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        store.selection = min(max(0, store.selection + delta), count - 1)
    }
}

/// One copied thing, drawn by its type. Click pastes it; hover shows pin and delete.
struct ClipTile: View {
    let item: ClipItem
    @ObservedObject var store: ClipboardStore
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    private enum Look { case link(URL), color(String), code, text, image, files }

    private var look: Look {
        switch item.kind {
        case .image: return .image
        case .files: return .files
        case .text:
            let t = item.preview
            if let url = URL(string: t), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil, !t.contains(" ") {
                return .link(url)
            }
            // "#1a2b3c", or bare hex with letters and digits: "482913" is a code, "facade" a word.
            if t.range(of: #"^#[0-9A-Fa-f]{6}$|^(?=.*[A-Fa-f])(?=.*[0-9])[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil {
                return .color(t.hasPrefix("#") ? t : "#" + t)
            }
            // One line, no sentence: a command or a piece of code.
            if !t.contains("\n"), t.count <= 80, t.range(of: #"[\$/=\(\)\{\}_\-]{1}"#, options: .regularExpression) != nil,
               t.range(of: #"\.\s|,\s"#, options: .regularExpression) == nil { return .code }
            return .text
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                content
                if hover || item.pinned { actions.padding(8) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
            .tile(selected ? .selected : .plain)
            .brightness(hover ? 0.04 : 0)
            .contentShape(RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
        .help(item.kind == .text ? String((item.text ?? "").prefix(600)) : item.preview)
    }

    @ViewBuilder private var content: some View {
        switch look {
        case .image:
            ZStack(alignment: .bottomLeading) {
                if let image = store.thumbnail(for: item) {
                    // The clear base takes the tile's size; a filled image as its own frame would grow the tile
                    // to the picture's proportions and spill over the next row.
                    Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
                } else {
                    Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 34)
                Text(footer(L("Картинка"))).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 12).padding(.bottom, 9)
            }
        case .link(let url):
            column(icon: "link", color: Tone.limit, title: L("Ссылка")) {
                Text(url.host ?? item.preview).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text(url.path.isEmpty ? " " : url.path + (url.query.map { "?" + $0 } ?? ""))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    .truncationMode(.middle)
            }
        case .color(let hex):
            column(icon: nil, color: Tone.ink, title: "") {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.color(hex)).frame(width: 36, height: 36)
                    Text(hex.uppercased()).font(.system(size: 12.5, design: .monospaced))
                }
            }
        case .files:
            let files = item.files ?? []
            column(icon: nil, color: Tone.ink, title: "") {
                HStack(spacing: 9) {
                    Image(nsImage: FileIcon.byType(files.first ?? "/")).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.preview).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(files.count > 1 ? Format.count(files.count, "файл", "файла", "файлов") : L("Файл"))
                            .font(.system(size: 10.5)).foregroundStyle(muted)
                    }
                }
            }
        case .code:
            column(icon: "terminal", color: Tone.ink, title: L("Текст")) {
                Text(item.preview).font(.system(size: 11, design: .monospaced)).lineLimit(2)
            }
        case .text:
            column(icon: "text.alignleft", color: Tone.ink, title: L("Текст")) {
                Text(item.preview.replacingOccurrences(of: "\n", with: " ⏎ ")).font(.system(size: 12)).lineSpacing(2).lineLimit(2)
            }
        }
    }

    /// Head (type), body, and where it came from at the bottom.
    private func column<Body: View>(icon: String?, color: Color, title: String, @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if item.pinned {
                TileHeader(symbol: "pin.fill", color: Tone.ink, title: L("Закреплено"), titleColor: .white.opacity(0.8))
                    .padding(.bottom, 8)
            } else if let icon {
                TileHeader(symbol: icon, color: color, title: title).padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 2) { body() }
            Spacer(minLength: 0)
            Text(footer(nil)).font(.system(size: 10.5)).foregroundStyle(muted).lineLimit(1)
        }
        .padding(Spacing.pad)
    }

    private func footer(_ kind: String?) -> String {
        [kind, item.sourceApp, Format.span(Date().timeIntervalSince(item.date))].compactMap { $0 }.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button { store.togglePin(item) } label: { small(item.pinned ? "pin.fill" : "pin") }
                .buttonStyle(.icon).focusable(false).help(item.pinned ? "Открепить" : "Закрепить")
            if hover {
                Button { store.delete(item, source: "row") } label: { small("xmark") }
                    .buttonStyle(.icon).focusable(false).help("Удалить")
            }
        }
    }

    private func small(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            .frame(width: 22, height: 22).background(Circle().fill(Color.black.opacity(0.55)))
    }

    private static func color(_ hex: String) -> Color {
        Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0)
    }
}
