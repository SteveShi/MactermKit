# MactermKit

[中文版](README_zh.md)

`MactermKit` is a highly cohesive Swift Package wrapper for the **Ghostty terminal emulation and rendering core**.

It decouples the native terminal simulation implementation, providing smooth rendering updates, native support for Chinese Input Method Editor (IME), configuration color theme expansions, and conforms strictly to the Swift 6 Concurrency safety specification.

---

## Core Features

1. **Cross-platform Compatibility (Stubs)**: Provides SwiftUI cross-platform wrapper `TerminalViewRepresentable`, and exposes `UITerminalView` stubs on the iOS platform for future evolution.
2. **Hardware High-Refresh-Rate Sync**: Integrates `MSDisplayLink`. When Ghostty triggers a Wakeup draw request, it defers rendering to coordinate with the vertical sync signal of the screen (VSYNC, e.g., 120Hz), eliminating useless CPU spin cycles and significantly reducing CPU overhead.
3. **Color Theme Integration (GhosttyTheme)**: Pre-packaged with beautiful themes like Dracula, GitHub Dark, GitHub Light, Gruvbox Dark, and Doom One. Supports real-time theme hot-swapping.
4. **Swift 6 Concurrency Safety**: The entire module strictly follows the Swift 6 Concurrency safety specifications, using `@MainActor` to isolate UI state and eliminate data races.
5. **Sandboxed Shell Simulation (ShellCraftKit)**: Retains stubs and APIs for executing sandboxed shell commands in-process for future command mock expansion.

---

## Dependencies

Add this package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SteveShi/MactermKit.git", from: "1.0.13")
]
```

And depend on `"MactermKit"` in your application targets.

*Note: This package internally links the C binary static library `GhosttyKit.xcframework`.*

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
    
    /// View constructor
    public init(runtime: GhosttyRuntime = .shared, config: GhosttySurfaceConfiguration = GhosttySurfaceConfiguration())
    
    /// Applies a theme at runtime (dynamic hot-swap)
    public func applyTheme(_ theme: GhosttyThemeDefinition)
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
