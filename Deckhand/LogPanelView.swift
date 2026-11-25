import AppKit
import DeckhandCore
import SwiftUI

/// The device log: search, level and app filters, and a live list that follows the tail.
struct LogPanelView: View {
    let device: Device
    let model: LogViewModel
    let kind: Binding<PanelKind>
    let isFull: Bool
    let onToggleFull: () -> Void
    let onClose: () -> Void

    @AppStorage("logColumnLayout") private var layoutJSON = ""
    /// Following the newest line. Scrolling up with the trackpad or wheel turns it off, reaching the end turns it on.
    @State private var isAtBottom = true
    @State private var endIsVisible = true
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var followTask: Task<Void, Never>?
    @State private var selection: Set<Int> = []
    @State private var selectionAnchor: Int?
    @State private var scrollRequest = 0
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            filterBar(filter: $model.filter)
            Divider()
            PanelColumnHeader(layout: Binding(get: { layout }, set: { layout = $0 }), showsTimeFormat: true)
            Divider()
            content
        }
        .background(.background)
        // a fresh log, and a freshly opened panel, start at the end and follow it
        .onAppear { isAtBottom = true }
        .onChange(of: model.visible.isEmpty) { _, empty in
            if empty { isAtBottom = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            PanelKindPicker(kind: kind)
            status
            Spacer()
            headerButton(model.isPaused ? "play.fill" : "pause.fill", model.isPaused ? "Resume" : "Pause") {
                model.isPaused.toggle()
            }
            headerButton("arrow.down.to.line", isAtBottom ? "Following the newest line" : "Jump to the newest line and follow",
                         tint: isAtBottom ? .accentColor : .secondary) { scrollRequest += 1 }
            copyMenu
            headerButton("trash", "Clear") { model.clear() }
            Divider().frame(height: 14)
            headerButton(isFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         isFull ? "Show the tools again" : "Use the whole right panel", action: onToggleFull)
            headerButton("xmark", "Close the log", action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .streaming:
            Text(model.filter.isActive ? "\(model.visible.count) of \(model.totalCount)" : "\(model.totalCount) lines")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if model.isPaused {
                Text("paused · \(model.queuedWhilePaused) waiting").font(.system(size: 11)).foregroundStyle(.orange)
            }
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
        case .idle:
            Text(device.state == .running ? "" : "Start the device to see its log")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func headerButton(_ symbol: String, _ help: String, tint: Color = .secondary,
                              action: @escaping () -> Void) -> some View {
        PanelHeaderButton(symbol: symbol, help: help, tint: tint, action: action)
    }

    // MARK: Filters

    private func filterBar(filter: Binding<LogFilter>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: filter.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !filter.wrappedValue.query.isEmpty {
                    Button { filter.wrappedValue.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Toggle(isOn: filter.isRegex) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .toggleStyle(.button)
                .controlSize(.mini)
                .help("Treat the search as a regular expression")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filter.wrappedValue.isValid ? Color.clear : Color.red))

            Menu {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Button {
                        filter.wrappedValue.minimumLevel = level
                    } label: {
                        Label(level.title, systemImage: filter.wrappedValue.minimumLevel == level ? "checkmark" : "")
                    }
                }
            } label: {
                Text(filter.wrappedValue.minimumLevel == .verbose ? "All levels" : "≥ \(filter.wrappedValue.minimumLevel.title)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            appsMenu(filter: filter)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottomTrailing) {
            if let tool = model.discoveryMissingTool {
                HStack(spacing: 6) {
                    Text("Needs \(tool.displayName)").font(.system(size: 10)).foregroundStyle(.orange)
                    InstallToolButton(tool: tool, title: "How to install")
                }
                .padding(.trailing, 10).offset(y: 9)
            } else if let message = model.discoveryMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
                    .padding(.trailing, 10).offset(y: 9)
            }
        }
    }

    private func appsMenu(filter: Binding<LogFilter>) -> some View {
        AppFilterButton(selection: filter.apps, apps: model.apps, yourApps: model.yourApps,
                        isFindingApp: model.isFindingApp, message: model.discoveryMessage,
                        onCurrentApp: { Task { await model.filterToCurrentApp() } },
                        loadYourApps: { await model.loadYourApps() })
    }

    // MARK: Columns

    private var layout: LogColumnLayout {
        get { LogColumnLayout(json: layoutJSON) ?? LogColumnLayout() }
        nonmutating set { layoutJSON = newValue.json }
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if model.visible.isEmpty {
            VStack {
                Spacer()
                Text(emptyText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.visible) { entry in
                            LogRow(entry: entry, layout: layout, isSelected: selection.contains(entry.id))
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture { select(entry) }
                                .contextMenu { contextMenu(for: entry) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                // the native anchor keeps the end in view as lines arrive; scrolling up releases it and the view stays put
                .onAppear {
                    if let last = model.visible.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onScrollPhaseChange { _, phase in scrollPhase = phase }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
                } action: { _, atEnd in
                    endIsVisible = atEnd
                    // only the user's own scrolling changes following: growing content briefly looks like "not at the end"
                    if scrollPhase == .interacting || scrollPhase == .decelerating { isAtBottom = atEnd }
                }
                .onChange(of: model.visible.last?.id) { _, last in
                    guard isAtBottom, let last else { return }
                    followTask?.cancel()
                    // lines can arrive faster than they are drawn, so scroll once per pause
                    followTask = Task {
                        try? await Task.sleep(for: .milliseconds(60))
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onChange(of: scrollRequest) { _, _ in
                    isAtBottom = true
                    if let last = model.visible.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(characters: CharacterSet(charactersIn: "a"), phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    selection = Set(model.visible.map(\.id))
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !selection.isEmpty else { return .ignored }
                    selection = []
                    return .handled
                }
                .onCopyCommand {
                    let text = model.text(of: selectedEntries)
                    return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
                }
            }
        }
    }

    private var emptyText: String {
        if model.state == .streaming, model.totalCount > 0 { return "No line matches the filter" }
        return model.state == .streaming ? "Waiting for log lines…" : ""
    }

    // MARK: Selection and copying

    private var selectedEntries: [LogEntry] {
        model.visible.filter { selection.contains($0.id) }
    }

    /// Click selects a line, Shift-click extends from the last click and Command-click toggles one.
    private func select(_ entry: LogEntry) {
        listFocused = true
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift), let anchor = selectionAnchor,
           let from = model.visible.firstIndex(where: { $0.id == anchor }),
           let to = model.visible.firstIndex(where: { $0.id == entry.id }) {
            selection = Set(model.visible[min(from, to)...max(from, to)].map(\.id))
        } else if flags.contains(.command) {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
            selectionAnchor = entry.id
        } else {
            selection = [entry.id]
            selectionAnchor = entry.id
        }
    }

    /// The lines an action applies to: the selection when the clicked line is part of it, else just that line.
    private func targets(for entry: LogEntry) -> [LogEntry] {
        selection.contains(entry.id) ? selectedEntries : [entry]
    }

    private var copyMenu: some View {
        Menu {
            if !selection.isEmpty {
                Button("Copy Selected Lines (\(selection.count))") { copy(model.text(of: selectedEntries)) }
                Button("Copy Selected Messages") { copy(model.messages(of: selectedEntries)) }
                Divider()
            }
            Button("Copy All Visible Lines") { copy(model.text()) }
            Button("Copy All Visible Messages") { copy(model.messages()) }
        } label: {
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy")
    }

    @ViewBuilder
    private func contextMenu(for entry: LogEntry) -> some View {
        let rows = targets(for: entry)
        Button(rows.count > 1 ? "Copy \(rows.count) Lines" : "Copy Line") { copy(model.text(of: rows)) }
        Button(rows.count > 1 ? "Copy \(rows.count) Messages" : "Copy Message") { copy(model.messages(of: rows)) }
        Divider()
        Button("Show Only \(entry.appName)") { model.filter.apps = [entry.appName] }
        Button("Hide \(entry.appName)") {
            model.filter.apps = Set(model.apps.map(\.name)).subtracting([entry.appName])
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct LogRow: View {
    let entry: LogEntry
    let layout: LogColumnLayout
    var isSelected = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(layout.visible, id: \.self) { column in
                cell(column)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
    }

    @ViewBuilder
    private func cell(_ column: LogColumn) -> some View {
        switch column {
        case .time:
            Text(layout.timeFormat.format(entry.time)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: layout.width(of: .time), alignment: .leading)
        case .level:
            Text(entry.level.letter).fontWeight(.bold).foregroundStyle(color)
                .frame(width: layout.width(of: .level), alignment: .leading)
        case .app:
            Text(entry.appName).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: layout.width(of: .app), alignment: .leading)
        case .tag:
            Text(entry.tag).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: layout.width(of: .tag), alignment: .leading)
        case .pid:
            Text(entry.pid.map(String.init) ?? "").foregroundStyle(.secondary).lineLimit(1)
                .frame(width: layout.width(of: .pid), alignment: .leading)
        case .message:
            Text(entry.message).foregroundStyle(entry.level >= .error ? Color.red : Color.primary).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var color: Color {
        switch entry.level {
        case .verbose, .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error, .fault: .red
        }
    }
}
