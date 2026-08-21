# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`libghostty-swift` is a Swift Package that wraps the **Ghostty terminal emulation and rendering core** (written in C/Zig). It provides a macOS-native terminal view with smooth rendering, IME support, theme management, and strict Swift 6 concurrency safety.

The package targets **macOS 15+** and depends on:
- `GhosttyKit.xcframework` (binary target, C library compiled from upstream Ghostty)
- `MSDisplayLink` (for VSYNC-coordinated rendering)
- Runtime dependency: `libghostty-vt.dylib` (must be linked by client applications)

## Build Commands

```bash
# Build the Swift package
swift build

# Run tests
swift test

# Build GhosttyKit.xcframework from upstream Ghostty source
# Requires Zig 0.15.2 in PATH or at /opt/homebrew/opt/zig@0.15/bin/zig
./scripts/build_ghostty.sh <version>  # e.g., v1.3.1

# Compute checksum for binary target (after building xcframework)
swift package compute-checksum ThirdParty/GhosttyKit.xcframework.zip
```

The `build_ghostty.sh` script:
1. Clones/updates `ghostty-org/ghostty` to `ThirdParty/src/ghostty`
2. Checks out the specified version tag
3. Runs `zig build -Dapp-runtime=none -Demit-xcframework=true`
4. Copies the resulting `GhosttyKit.xcframework` to `ThirdParty/lib/`

## Architecture

### Core Components

1. **GhosttyRuntime** (`GhosttyRuntime.swift`)
   - `@MainActor` singleton managing the global Ghostty app lifecycle
   - Holds `ghostty_app_t` and `ghostty_config_t` C handles
   - Implements `DisplayLinkDelegate` to coordinate rendering with VSYNC
   - Maintains a weak registry of `GhosttySurfaceView` instances by address (for safe cross-thread callback lookups)
   - Tracks `activeSurface` for clipboard operations

2. **GhosttySurfaceView** (`GhosttySurfaceView.swift`)
   - `@MainActor` NSView subclass that hosts terminal rendering
   - Conforms to `NSTextInputClient` for Chinese/Japanese IME support
   - Wraps `ghostty_surface_t` C handle
   - Registers itself with `GhosttyRuntime` using its memory address as a stable key
   - Handles keyboard events, mouse events, and clipboard operations

3. **GhosttyTheme** (`GhosttyTheme/`)
   - `GhosttyThemeDefinition`: Sendable struct defining colors and palette
   - `GhosttyThemeCatalog`: Static catalog of pre-defined themes (Dracula, GitHub Dark/Light, Gruvbox, etc.)
   - Themes can be applied at runtime via `GhosttySurfaceView.applyTheme(_:)`

4. **Platform Stubs** (`PlatformStubs/`)
   - `TerminalViewRepresentable`: SwiftUI wrapper for cross-platform compatibility
   - `UITerminalView`: iOS stub for future evolution

5. **ShellCraftKit** (`ShellCraftKit/`)
   - Stubs for sandboxed in-process shell command execution (future expansion)

### Swift 6 Concurrency & Thread Safety

**Critical constraint**: All code must maintain Swift 6 concurrency safety.

- **@MainActor isolation**: `GhosttyRuntime` and `GhosttySurfaceView` are `@MainActor` because they interact with AppKit UI.
- **C callbacks from background threads**: Ghostty's renderer calls Swift callbacks from background threads. To avoid data races:
  - Callbacks must be **top-level functions** (not closures) with no implicit actor isolation
  - Pass stable identifiers (memory addresses as `Int`) instead of raw pointers across threads
  - Use `DispatchQueue.main.async` to hop back to the main actor
  - Use weak registry lookups to avoid use-after-free when views are deallocated

**Example pattern** (see `ghostty_wakeup_callback` in `GhosttyRuntime.swift`):
```swift
// Top-level function, no actor isolation
private func ghostty_wakeup_callback(userdata: UnsafeMutableRawPointer?) {
    let bitPattern = Int(bitPattern: userdata)  // Convert to Sendable Int
    DispatchQueue.main.async {
        let opaque = UnsafeMutableRawPointer(bitPattern: bitPattern)!
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(opaque).takeUnretainedValue()
        runtime.setPendingTick()  // Now safe on @MainActor
    }
}
```

### Rendering Flow

1. Ghostty's C renderer detects changes and calls `ghostty_wakeup_callback` from a background thread
2. Callback dispatches to main queue and calls `GhosttyRuntime.setPendingTick()`
3. `MSDisplayLink` fires on next VSYNC
4. `GhosttyRuntime.appTick()` calls `ghostty_app_tick()` to render pending frames
5. Ghostty draws into the Metal layer of `GhosttySurfaceView`

This eliminates CPU spin-wait and synchronizes with the display's refresh rate (e.g., 120Hz).

### Auto-Update Workflow

`.github/workflows/auto_update.yml` runs daily and on push:
1. Fetches latest stable Ghostty release tag from `ghostty-org/ghostty`
2. Compares with `upstream_ghostty.txt` (current version)
3. If newer, runs `build_ghostty.sh` to compile `GhosttyKit.xcframework`
4. Computes checksum and updates `Package.swift` with new release URL
5. Creates a new GitHub release with the xcframework zip
6. Commits version bump with `[skip ci]`

## Key Constraints & Patterns

- **No tests directory**: This package currently has no unit tests. When adding tests, ensure they mock C calls or use integration testing patterns.
- **Binary target versioning**: `Package.swift` references a specific GitHub release URL for `GhosttyKit.xcframework`. When updating, you must:
  1. Build the xcframework
  2. Create a new GitHub release with the zip
  3. Update the URL and checksum in `Package.swift`
- **IME handling**: `GhosttySurfaceView` accumulates marked text and interprets commands via `NSTextInputClient`. Terminal control keys (arrows, delete, etc.) bypass IME and go directly to Ghostty.
- **Clipboard operations**: Ghostty requests clipboard access via callbacks. The runtime uses the `activeSurface` to determine which surface should handle the request.
- **View lifecycle**: `GhosttySurfaceView` uses a two-pass layout strategy (`viewDidMoveToWindow`) to ensure the PTY receives correct window size after SwiftUI layout resolves.

## Making Changes

When modifying this codebase:

1. **Maintain Swift 6 safety**: Never introduce data races. Use `@MainActor` for UI code and follow the callback pattern for C interop.
2. **Test with IME**: If touching keyboard/input handling, test with Chinese/Japanese input methods.
3. **Verify rendering**: Changes to `GhosttyRuntime` or `GhosttySurfaceView` should be tested with a real terminal session to ensure smooth rendering.
4. **Update both READMEs**: Changes to public APIs should be reflected in both `README.md` and `README_zh.md`.
5. **Binary target updates**: If updating Ghostty version, follow the auto-update workflow pattern or run it manually with `workflow_dispatch`.

<!-- BEGIN brain.md -->
## Project Brain

This project keeps a **Project Brain**: a persistent memory layer of its durable decisions, requirements, and constraints. Read `./BRAIN.md` for the full read/write contract.
@import ./BRAIN.md

Maintain the brain as part of normal coding work — not as a separate task. While discussing or implementing features:
- **Start of a task:** load relevant context with the `brain` CLI (`list-pages`, `read-page`, `read-root`). Prefer a narrow read over scanning everything.
- **When a decision, requirement, constraint, or durable insight settles** (in chat or while coding): capture it immediately via the `brain` CLI. Do not wait to be asked and do not batch it for later.
- **Pure implementation with no new decision:** do not write to the brain.
- **When overturning a prior conclusion:** update the page (`update-truth` and/or `append-timeline` with `kind: reversal`, or `archive-page`).
- Only store what will still matter in six months and is hard to reconstruct from the code alone.
- All reads and writes go through the `brain` CLI — never hand-edit brain files.

The brain skills (`brain-setup`, `brain-page`, `brain-ingest`, `brain-bootstrap`) are installed in your global skills directory. Prefer `brain init` to scaffold a new project.
<!-- END brain.md -->
