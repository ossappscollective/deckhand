import AppKit
import DeckhandCore
import SwiftUI

/// What to do about an open source program Deckhand can use but does not find: where it lives and how to install it.
struct MissingToolPopover: View {
    let tool: OptionalTool
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(tool.displayName) is not installed", systemImage: "shippingbox")
                .font(.system(size: 13, weight: .semibold))
            Text(tool.benefit)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(tool.installCommand)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tool.installCommand, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            Button { openURL(tool.homepage) } label: {
                Label("Open the \(tool.displayName) project", systemImage: "arrow.up.right.square")
            }
            .controlSize(.small)
            Text("Then start the mirror again, or reopen this panel.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

/// A button that opens the install help for `tool`.
struct InstallToolButton: View {
    let tool: OptionalTool
    var title: String?
    @State private var shown = false

    var body: some View {
        Button(title ?? "Install \(tool.displayName)…") { shown = true }
            .controlSize(.small)
            .popover(isPresented: $shown, arrowEdge: .top) { MissingToolPopover(tool: tool) }
    }
}
