# MactermKit

[中文版](README_zh.md)

`MactermKit` is a highly cohesive Swift Package wrapper for the **Ghostty terminal emulation and rendering core**.

It decouples the native terminal simulation implementation, providing smooth rendering updates, native support for Chinese Input Method Editor (IME), configuration color theme expansions, and conforms strictly to the Swift 6 Concurrency safety specification.

---

## Core Features

1. **Ghostty v1.4.0 Core Engine**: Built upon upstream Ghostty 1.4.0 with Zig 0.17 toolchain, supporting modern terminal escape sequences, Metal-accelerated rendering, and low latency.
2. **Program Status Protocol (OSC 7501)**: Full end-to-end integration of the OSC 7501 protocol reporting real-time CLI tool execution status, state changes (working, idle, done, blocked, error), kinds (permission, question, auth), and percentage progress.
3. **ConEmu Progress Protocol (OSC 9;4)**: Native parsing of task progress states (set, remove, error, indeterminate, pause) and percentage indicators.
4. **Process & TTY Introspection**: Exposes the root shell process ID (`processID` / `ptyPID`), the active foreground subshell PID (`foregroundProcessID`), and the assigned TTY device node (`ttyName`).
5. **Bracketed Paste & Safety Protection**: Provides `pasteText(_:)` utilizing Ghostty's core paste pipeline (bracketed paste, Kitty paste modes, and safety checks against unexpected returns).
6. **Dynamic Cursor Shapes & Link Hover**: Maps Ghostty's semantic mouse shapes to AppKit `NSCursor`, with real-time hover notifications for hyperlinks (`hoverLink`).
7. **Hardware High-Refresh-Rate Sync**: Integrates `MSDisplayLink`. When Ghostty triggers a Wakeup draw request, it defers rendering to coordinate with the vertical sync signal of the screen (VSYNC, e.g., 120Hz), eliminating useless CPU spin cycles and significantly reducing CPU overhead.
8. **Color Theme Integration & Dark Mode**: Pre-packaged with beautiful themes (Dracula, GitHub Dark/Light, Gruvbox, Doom One). Supports runtime theme switching and explicit system appearance adjustments (`setColorScheme(isDark:)`).
9. **Swift 6 Concurrency Safety**: The entire module strictly follows the Swift 6 Concurrency safety specifications, using `@MainActor` to isolate UI state and eliminate data races.

---

## Dependencies

Add this package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SteveShi/MactermKit.git", from: "1.0.15")
]
```

And depend on `"MactermKit"` in your application targets.

*Note: This package internally links the binary static library `MactermKitCore.xcframework`.*

---

## Core APIs & Interface Descriptions

### 1. `GhosttyRuntime`
Global terminal environment runtime manager. Handles Ghostty initialization, configuration loading, lifecycle, and background wakeup callbacks.

```swift
@MainActor
public final class GhosttyRuntime: DisplayLinkDelegate {
    /// Singleton access
    public static let shared: GhosttyRuntime
    
    /// Underlying C App Handle
    public private(set) var app: ghostty_app_t?
    
    /// Underlying Global C Config
    public private(set) var config: ghostty_config_t?

    /// Sets the color scheme (light or dark) across all surfaces of the Ghostty app
    public func setColorScheme(isDark: Bool)
    
    /// Flags pending frames to be consumed by DisplayLink ticks
    public func setPendingTick()
    
    /// Triggers a single tick on the underlying rendering loop
    public func appTick()
}
```

### 2. `GhosttySurfaceView`
The view that hosts terminal rendering (subclass of `NSView` on macOS, conforming to `NSTextInputClient` for Chinese input method handling).

```swift
@MainActor
public class GhosttySurfaceView: NSView, NSTextInputClient {
    /// The associated runtime instance
    public let runtime: GhosttyRuntime
    
    /// Underlying C Surface Handle
    public var rawSurface: ghostty_surface_t? { get }

    /// Root PID of the shell process running in this surface's PTY
    public var processID: pid_t? { get }

    /// Backward-compatible alias for `processID`
    public var ptyPID: pid_t? { get }

    /// Foreground process PID currently executing in the terminal
    public var foregroundProcessID: pid_t? { get }

    /// Assigned TTY device path (e.g. "/dev/ttys001")
    public var ttyName: String? { get }

    /// Whether this surface is marked as occluded
    public private(set) var isOccluded: Bool

    /// Informs Ghostty whether the surface is occluded
    public func setOccluded(_ occluded: Bool)

    /// Sets the color scheme (light or dark) for this surface
    public func setColorScheme(isDark: Bool)
    
    /// View constructor
    public init(runtime: GhosttyRuntime = .shared, config: GhosttySurfaceConfiguration = GhosttySurfaceConfiguration())
    
    /// Applies a theme at runtime (dynamic hot-swap)
    public func applyTheme(_ theme: GhosttyThemeDefinition)

    /// Pastes text using Ghostty's bracketed paste and safety protections
    public func pasteText(_ text: String)
    
    /// Reads the entire scrollback buffer and active screen content as plain text
    public func readFullText(maxLines: Int = 10000) -> String?
    
    /// Reads the entire scrollback buffer and active screen content with VT formatting (ANSI SGR escape sequences)
    public func readFullVTText(maxLines: Int = 10000) -> String?
}
```

### 3. `GhosttySurfaceConfiguration`
Configuration parameters used to instantiate a `GhosttySurfaceView`.

```swift
public struct GhosttySurfaceConfiguration: Sendable {
    public var fontSize: Float
    public var workingDirectory: String?
    public var command: String?
    public var environmentVariables: [String: String]
    public var initialInput: String?
    public var waitAfterCommand: Bool
    
    public init(
        fontSize: Float = 0,
        workingDirectory: String? = nil,
        command: String? = nil,
        environmentVariables: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false
    )
}
```

### 4. `GhosttyThemeDefinition` & `GhosttyThemeCatalog`
Theme models and catalog retrieval APIs.

```swift
public struct GhosttyThemeDefinition: Sendable, Hashable, Identifiable {
    public let name: String
    public let background: String
    public let foreground: String
    public let cursorColor: String?
    public let cursorText: String?
    public let selectionBackground: String?
    public let selectionForeground: String?
    public let palette: [Int: String]
    
    /// True if the theme background indicates a dark palette
    public var isDark: Bool { get }
}

public enum GhosttyThemeCatalog {
    /// Array of statically pre-defined themes
    public static let allThemes: [GhosttyThemeDefinition]
    
    /// Find theme matching exact name (case-insensitive)
    public static func theme(named name: String) -> GhosttyThemeDefinition?
    
    /// Search themes by matching query substring
    public static func search(_ query: String) -> [GhosttyThemeDefinition]
}
```

---

## Quick Start Example

### Initialize Runtime and Surface View

```swift
import SwiftUI
import libghostty_swift

// 1. Set up terminal configurations
var config = GhosttySurfaceConfiguration()
config.fontSize = 14
config.workingDirectory = NSHomeDirectory()
config.command = "/usr/bin/ssh steve@192.168.1.1"

// 2. Instantiate Surface View
let terminalView = GhosttySurfaceView(config: config)

// 3. Hot-swap color theme
if let dracula = GhosttyThemeCatalog.theme(named: "Dracula") {
    terminalView.applyTheme(dracula)
}
```
