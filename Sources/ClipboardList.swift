import AppKit
import SwiftUI

// MARK: Clipboard (keyboard first: type to filter, ↑↓ to choose, ↩ to paste, ⌘C to copy; the chosen entry in full
// beside the list). ⌘1 from the search opens it over the search, and Esc or ⌘1 goes back.

struct ClipboardTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: ClipboardStore
    @FocusState private var searchFocused: Bool
    @Namespace private var selectionSpace

    static let listWidth: CGFloat = 290

    var body: some View {
        let items = store.filtered
        // Deleting the last entry or clearing around pinned ones shortens the list under the selection: show the
        // nearest entry instead of the empty state (`onChange` below moves the selection itself).
        let index = items.isEmpty ? nil : min(max(store.selection, 0), items.count - 1)
        VStack(spacing: Spacing.gap) {
            searchRow(items).entrance(0)
            if let index {
                HStack(alignment: .top, spacing: Spacing.gap) {
                    list(items, selection: index).frame(width: Self.listWidth)
                    ClipPreview(item: items[index], store: store)
                }
                .entrance(1)
            } else {
                Tile {
                    VStack(spacing: 8) {
                        TileIcon(symbol: store.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass", color: Tone.info, size: 40)
                        Text(store.query.isEmpty && store.filter == .all ? L("Скопируйте что-нибудь — оно появится здесь") : L("Ничего не найдено"))
                            .font(.system(size: 12)).foregroundStyle(muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .entrance(1)
            }
        }
        // Focus only when Nook owns the keyboard (opened with a hotkey); otherwise typing stays in your app.
        .onAppear { if model.sticky && model.panel?.isKeyWindow == true { searchFocused = true } }
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
        .onChange(of: items.count) { _, count in
            if store.selection >= count { store.selection = max(0, count - 1) }
        }
    }

    // MARK: Field

    private func searchRow(_ items: [ClipItem]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                if model.clipboardFromSearch {
                    Button { model.switchSearchClipboard() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 16, height: 22)
                    }
                    .buttonStyle(.icon).focusable(false).foregroundStyle(muted).help("Назад к поиску (Esc)")
                } else {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(muted)
                }
                TextField("Поиск в буфере", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { if items.indices.contains(store.selection) { model.pick(items[store.selection]) } }
                    .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                    .onKeyPress(.escape) { model.escapeKey(); return .handled }
                    .onChange(of: store.query) { _, _ in store.selection = 0 }
                hints
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

    /// What ↩ and ⌘C do, with the app ↩ pastes into.
    @ViewBuilder private var hints: some View {
        if AXIsProcessTrusted() {
            // ↩ pastes only into the app a hotkey opened the panel from; opened by hover it copies, like ⌘C.
            HStack(spacing: 5) {
                KeyCap(text: "↩")
                if let target = model.pasteTargetName {
                    Text(L("в \(target)")).lineLimit(1)
                    KeyCap(text: "⌘C").padding(.leading, 4)
                }
                Text("копировать")
            }
            .font(.system(size: 11)).foregroundStyle(faint)
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

    private func square(_ symbol: String, active: Bool = false) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? Tone.info : .white.opacity(0.7))
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    // MARK: List

    private func list(_ items: [ClipItem], selection: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipLine(item: item, store: store, selected: index == selection, selectionSpace: selectionSpace,
                                 select: { store.selection = index; model.takeKeyboard() }, pick: { model.pick(item) })
                            .contextMenu { menu(item) }
                            .id(item.id)
                    }
                }
                .animation(Motion.quick, value: store.selection)
                .animation(Motion.smooth, value: items.map(\.id))
            }
            .defaultScrollAnchor(.top)
            .onChange(of: store.selection) { _, new in
                if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
            }
        }
    }

    @ViewBuilder private func menu(_ item: ClipItem) -> some View {
        Button(model.sticky && AXIsProcessTrusted() ? L("Вставить") : L("Скопировать")) { model.pick(item) }
        Button("Только скопировать") { model.copyClip(item) }
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

/// What a copied text is, for its icon and preview.
enum ClipLook: Equatable {
    case link(URL), color(String), code, text, image, files

    init(_ item: ClipItem) {
        switch item.kind {
        case .image: self = .image
        case .files: self = .files
        case .text:
            let t = item.preview
            if let url = URL(string: t), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil, !t.contains(" ") {
                self = .link(url)
            } else if t.range(of: #"^#[0-9A-Fa-f]{6}$|^(?=.*[A-Fa-f])(?=.*[0-9])[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil {
                // "#1a2b3c", or bare hex with letters and digits: "482913" is a code, "facade" a word.
                self = .color(t.hasPrefix("#") ? t : "#" + t)
            } else if !t.contains("\n"), t.count <= 80, t.range(of: #"[\$/=\(\)\{\}_\-]{1}"#, options: .regularExpression) != nil,
                      t.range(of: #"\.\s|,\s"#, options: .regularExpression) == nil {
                // One line, no sentence: a command or a piece of code.
                self = .code
            } else {
                self = .text
            }
        }
    }

    var title: String {
        switch self {
        case .link: L("Ссылка")
        case .color: L("Цвет")
        case .code: L("Код")
        case .text: L("Текст")
        case .image: L("Картинка")
        case .files: L("Файл")
        }
    }

    var symbol: String {
        switch self {
        case .link: "link"
        case .color: "paintpalette"
        case .code: "terminal"
        case .text: "text.alignleft"
        case .image: "photo"
        case .files: "doc"
        }
    }

    static func color(_ hex: String) -> Color { Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0) }
}

/// One entry in the list: its icon (or the picture itself), one line of it, a pin when pinned.
private struct ClipLine: View {
    let item: ClipItem
    @ObservedObject var store: ClipboardStore
    let selected: Bool
    let selectionSpace: Namespace.ID
    let select: () -> Void
    let pick: () -> Void
    @State private var hover = false

    var body: some View {
        let look = ClipLook(item)
        Button(action: select) {
            HStack(spacing: 10) {
                icon(look).frame(width: 22, height: 22)
                Text(title(look)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if hover {
                    Button { store.delete(item, source: "row") } label: {
                        Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.icon).focusable(false).foregroundStyle(muted).help("Удалить")
                }
                if item.pinned || hover {
                    Button { store.togglePin(item) } label: {
                        Image(systemName: item.pinned ? "pin.fill" : "pin").font(.system(size: 10)).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.icon).focusable(false).foregroundStyle(item.pinned ? .white.opacity(0.8) : muted)
                    .help(item.pinned ? "Открепить" : "Закрепить")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if selected {
                    shape.fill(Surface.raised)
                        .overlay(shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5))
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                } else if hover {
                    shape.fill(Color.white.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        // Click chooses, a double click pastes, like ↩.
        .simultaneousGesture(TapGesture(count: 2).onEnded { pick() })
        .onHover { hover = $0 }
        .help(item.kind == .text ? String((item.text ?? "").prefix(600)) : item.preview)
    }

    private func title(_ look: ClipLook) -> String {
        switch look {
        case .image: return item.sourceApp.map { L("Картинка · \($0)") } ?? L("Картинка")
        case .link(let url): return (url.host ?? "") + url.path
        default: return item.preview.replacingOccurrences(of: "\n", with: " ⏎ ")
        }
    }

    @ViewBuilder private func icon(_ look: ClipLook) -> some View {
        switch look {
        case .image:
            if let image = store.thumbnail(for: item) {
                Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                TileIcon(symbol: "photo", color: Tone.ink, size: 22)
            }
        case .files:
            Image(nsImage: FileIcon.byType(item.files?.first ?? "/")).resizable().frame(width: 20, height: 20)
        case .color(let hex):
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ClipLook.color(hex)).frame(width: 18, height: 18)
        case .link:
            TileIcon(symbol: look.symbol, color: Tone.limit, size: 22)
        default:
            TileIcon(symbol: look.symbol, color: Tone.ink, size: 22)
        }
    }
}

/// The chosen entry in full, and what is known about it: where it came from, what it is, how big, when.
private struct ClipPreview: View {
    let item: ClipItem
    @ObservedObject var store: ClipboardStore

    var body: some View {
        let look = ClipLook(item)
        VStack(alignment: .leading, spacing: 0) {
            content(look).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.vertical, 10)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                GridRow {
                    fact(L("Источник"), item.sourceApp ?? "—")
                    fact(L("Тип"), item.kind == .files && (item.files?.count ?? 0) > 1 ? L("Файлы") : look.title)
                }
                GridRow {
                    fact(L("Размер"), size(look))
                    fact(L("Скопировано"), Format.when(item.date))
                }
            }
        }
        .padding(Spacing.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile()
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Caps(text: label, color: faint)
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func size(_ look: ClipLook) -> String {
        switch item.kind {
        case .image:
            guard let info = store.imageInfo(for: item) else { return "…" }
            return "\(info.width)×\(info.height) · " + ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file)
        case .files:
            let n = item.files?.count ?? 0
            return Format.count(n, "файл", "файла", "файлов")
        case .text:
            let text = item.text ?? ""
            let lines = text.split(whereSeparator: \.isNewline).count
            return Format.count(text.count, "символ", "символа", "символов")
                + (lines > 1 ? " · " + Format.count(lines, "строка", "строки", "строк") : "")
        }
    }

    @ViewBuilder private func content(_ look: ClipLook) -> some View {
        switch look {
        case .image:
            if let image = store.thumbnail(for: item) {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .link(let url):
            VStack(alignment: .leading, spacing: 4) {
                Text(url.host ?? item.preview).font(.system(size: 16, weight: .bold)).lineLimit(1)
                Text(item.preview).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(4).truncationMode(.middle)
            }
        case .color(let hex):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ClipLook.color(hex)).frame(width: 52, height: 52)
                Text(hex.uppercased()).font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
        case .code:
            Text(item.preview).font(.system(size: 12, design: .monospaced)).lineSpacing(2).lineLimit(6)
        case .text:
            Text(item.preview).font(.system(size: 12.5)).lineSpacing(2).lineLimit(6)
        case .files:
            let files = item.files ?? []
            VStack(alignment: .leading, spacing: 6) {
                ForEach(files.prefix(3), id: \.self) { path in
                    HStack(spacing: 9) {
                        Image(nsImage: FileIcon.byType(path)).resizable().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text((path as NSString).lastPathComponent).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                .truncationMode(.middle)
                            Text(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 10.5)).foregroundStyle(faint).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                if files.count > 3 {
                    Text(L("и ещё \(files.count - 3)")).font(.system(size: 11)).foregroundStyle(faint)
                }
            }
        }
    }
}
