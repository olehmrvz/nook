import AppKit
import SwiftUI

// MARK: Settings building blocks
//
// The Settings window is drawn with plain stacks instead of NavigationSplitView and a grouped Form: those rebuilt
// every row on each pane switch and made the window feel slow. Groups of rows sit in graphite cards, like the
// tiles of the panel.

/// A pane's content: the header, then its groups, in one scroll view.
struct SettingsPage<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PaneHeader(pane: pane)
                content
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

/// A titled group of rows in a card; an optional line of explanation under it.
struct SettingsGroup<Content: View>: View {
    private let title: Text?
    private let footer: Text?
    private let content: Content

    init(_ title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title.map { Text($0) }
        self.footer = footer.map { Text($0) }
        self.content = content()
    }

    init(verbatim title: String, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: title)
        footer = nil
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                title.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).padding(.leading, 4)
            }
            // Every row draws a hairline at its top; the first one is pushed under the card's edge.
            VStack(spacing: 0) { content }
                .padding(.top, -1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Surface.tile)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
            if let footer {
                footer.font(.system(size: 11.5)).foregroundStyle(muted).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One line of a group with any content, the hairline above it included.
struct SettingsLine<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 14) }
    }
}

/// A row: a title (and a line under it) on the left, a control on the right.
struct SettingsRow<Accessory: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let accessory: Accessory

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.accessory = accessory()
    }

    /// Text that is already final (a name, a value from `L`). Disfavoured like SwiftUI's own `Text` overload: without
    /// it a string literal picked this one (String is the default literal type) and the row stayed in Russian.
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.accessory = accessory()
    }

    var body: some View {
        SettingsLine {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.system(size: 13))
                    if let subtitle { subtitle.font(.system(size: 11.5)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                accessory
            }
        }
    }
}

/// A switch row.
struct SettingsToggle<Label: View>: View {
    private let label: Label
    private let subtitle: Text?
    @Binding private var isOn: Bool

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, isOn: Binding<Bool>) where Label == Text {
        label = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        _isOn = isOn
    }

    init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.label = label()
        subtitle = nil
        _isOn = isOn
    }

    var body: some View {
        SettingsLine {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    label.font(.system(size: 13))
                    if let subtitle { subtitle.font(.system(size: 11.5)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
    }
}

/// A row with a pop-up menu of choices.
struct SettingsPicker<Value: Hashable, Options: View>: View {
    private let title: Text
    /// A line under the title about the chosen value; text already in the person's language.
    private let subtitle: String?
    @Binding private var selection: Value
    private let options: Options

    init(_ title: LocalizedStringKey, subtitle: String? = nil, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        self.title = Text(title)
        self.subtitle = subtitle
        _selection = selection
        self.options = options()
    }

    var body: some View {
        SettingsLine {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Picker("", selection: $selection) { options }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
            }
        }
    }
}

// MARK: Sidebar

/// Panes in three groups: what Nook shows, its tools, and Nook itself.
struct SettingsSidebar: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { i, group in
                if let title = group.title {
                    Caps(text: title).padding(.leading, 10).padding(.top, i == 0 ? 0 : 14).padding(.bottom, 4)
                }
                ForEach(group.panes) { row($0) }
            }
            Spacer(minLength: 0)
            Text("Nook \(Updater.version)").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 10)
        }
        .padding(.horizontal, 10).padding(.top, 52).padding(.bottom, 14)
        .frame(width: 220, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x111114))
    }

    private func row(_ pane: SettingsPane) -> some View {
        let selected = state.pane == pane
        return Button { state.pane = pane } label: {
            HStack(spacing: 10) {
                PaneIcon(pane: pane, size: 22)
                Text(pane.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
