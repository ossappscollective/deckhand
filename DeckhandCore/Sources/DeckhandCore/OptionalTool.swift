import Foundation

/// An open source program Deckhand can use when the user has installed it, and works without otherwise.
public enum OptionalTool: String, CaseIterable, Identifiable, Sendable {
    case scrcpy
    case baguette
    case bundletool

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .scrcpy: "scrcpy"
        case .baguette: "Baguette"
        case .bundletool: "bundletool"
        }
    }

    /// What the user gets by installing it.
    public var benefit: String {
        switch self {
        case .scrcpy: "A faster, sharper Android mirror with clipboard sync."
        case .baguette: "Touch and keyboard, rotation, the simulator camera and the foreground app for iOS simulators."
        case .bundletool: "Installing .aab app bundles on an Android device."
        }
    }

    public var homepage: URL {
        switch self {
        case .scrcpy: URL(string: "https://github.com/Genymobile/scrcpy")!
        case .baguette: URL(string: "https://github.com/tddworks/baguette")!
        case .bundletool: URL(string: "https://github.com/google/bundletool")!
        }
    }

    public var brewFormula: String { rawValue }

    public var installCommand: String { "brew install \(brewFormula)" }
}

/// An action needed an `OptionalTool` that is not installed.
public struct MissingToolError: LocalizedError, Equatable, Sendable {
    public let tool: OptionalTool
    /// What could not be done, e.g. "Rotating a simulator".
    public let action: String

    public init(_ tool: OptionalTool, for action: String) {
        self.tool = tool
        self.action = action
    }

    public var errorDescription: String? {
        "\(action) needs \(tool.displayName), which is not installed. Run: \(tool.installCommand)"
    }
}
