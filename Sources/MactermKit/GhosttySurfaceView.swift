import AppKit
import Foundation
import GhosttyKit

@MainActor
public class GhosttySurfaceView: NSView, @preconcurrency NSTextInputClient {
    public let runtime: GhosttyRuntime
    public var isReadOnly: Bool = false
    public var menuBuilder: (@MainActor (GhosttySurfaceView, NSEvent) -> NSMenu?)?
    private nonisolated(unsafe) var surface: ghostty_surface_t? = nil
    private var surfaceConfig = GhosttySurfaceConfiguration()
    private var markedText: String? = nil
    private var accumulatedTexts: [String]? = nil
    private var interpretedCommandSelector: Selector? = nil

    public var rawSurface: ghostty_surface_t? {
        surface
    }

    private static let fallbackBackingScaleFactor: CGFloat = 2.0

    private static let terminalControlKeyCodes: Set<UInt16> = [
        51, 117,            // Delete, Forward Delete
        36, 76,             // Return, Enter
        53, 48,             // Escape, Tab
        123, 124, 125, 126, // Left, Right, Down, Up arrows
        115, 119, 116, 121, // Home, End, Page Up, Page Down
    ]

    /// Stable identity used as the registry key for cross-thread C callbacks.
    private nonisolated var registryKey: Int {
        Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())
    }

    public init(runtime: GhosttyRuntime = .shared, config: GhosttySurfaceConfiguration = GhosttySurfaceConfiguration()) {
        self.runtime = runtime
        self.surfaceConfig = config
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.textArea)
        setupSurfaceIfPossible()
    }

    public required init?(coder: NSCoder) {
        fatalError("GhosttySurfaceView must be created programmatically; init(coder:) is not supported")
    }

    deinit {
        let surfaceToFree = surface
        let key = registryKey
        DispatchQueue.main.async { [runtime] in
            if let surfaceToFree, runtime.activeSurface == surfaceToFree {
                runtime.activeSurface = nil
            }
            runtime.unregisterSurfaceView(forKey: key)
            if let surfaceToFree {
                ghostty_surface_free(surfaceToFree)
            }
        }
    }

    override public var acceptsFirstResponder: Bool { true }

    override public func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = surface {
            ghostty_surface_set_focus(surface, true)
            runtime.activeSurface = surface
        }
        return result
    }

    override public func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface = surface {
            ghostty_surface_set_focus(surface, false)
            if runtime.activeSurface == surface {
                runtime.activeSurface = nil
            }
        }
        return result
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentScale()
        // First async pass: size may not be final yet (SwiftUI layout in-flight)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateSurfaceSize()
            self.window?.makeFirstResponder(self)
        }
        // Second pass with a short delay: ensures the PTY receives the correct
        // TIOCSWINSZ *after* Auto Layout has fully resolved the view frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updateSurfaceSize()
        }
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override public func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
        updateSurfaceSize()
    }

    override public func keyDown(with event: NSEvent) {
        if isReadOnly { return }
        guard let surface = surface else { return }
        
        let hasControlModifiers = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
        
        let isControlKey = Self.terminalControlKeyCodes.contains(event.keyCode)
        
        let isWritingPreedit = self.hasMarkedText()
        if isWritingPreedit || (!isControlKey && !hasControlModifiers) {
            self.accumulatedTexts = []
            self.interpretedCommandSelector = nil
            
            self.interpretKeyEvents([event])
            
            let collected = self.accumulatedTexts
            self.accumulatedTexts = nil
            
            if let collectedText = collected, !collectedText.isEmpty {
                for text in collectedText {
                    text.withCString { cStr in
                        ghostty_surface_text(surface, cStr, UInt(text.utf8.count))
                    }
                }
                NSAccessibility.post(element: self, notification: .valueChanged)
                return
            }
            
            if self.interpretedCommandSelector != nil {
                self.interpretedCommandSelector = nil
                if !isWritingPreedit {
                    sendDirectKey(event, to: surface)
                }
                NSAccessibility.post(element: self, notification: .valueChanged)
                return
            }
            
            return
        }
        
        sendDirectKey(event, to: surface)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    
    private func sendDirectKey(_ event: NSEvent, to surface: ghostty_surface_t) {
        var keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        if let text = event.ghosttyCharacters {
            text.withCString { cString in
                keyEvent.text = cString
                ghostty_surface_key(surface, keyEvent)
            }
        } else {
            ghostty_surface_key(surface, keyEvent)
        }
    }
    
    override public func doCommand(by selector: Selector) {
        self.interpretedCommandSelector = selector
    }

    override public func keyUp(with event: NSEvent) {
        guard let surface = surface else { return }
        let keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_RELEASE)
        ghostty_surface_key(surface, keyEvent)
    }

    override public func flagsChanged(with event: NSEvent) {
        guard let surface = surface else { return }
        let keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - Mouse events

    /// Forward the current mouse location to Ghostty. Ghostty's origin is top-left
    /// while AppKit's is bottom-left, so the Y axis is flipped (same convention as
    /// `scrollWheel`).
    private func sendMousePos(_ event: NSEvent) {
        guard let surface = surface else { return }
        let loc = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, loc.x, bounds.height - loc.y, event.ghosttyMouseMods)
    }

    /// Forward a mouse button press/release to Ghostty. The position is sent first
    /// so the core resolves the click against the correct cell.
    private func sendMouseButton(_ state: ghostty_input_mouse_state_e,
                                 _ button: ghostty_input_mouse_button_e,
                                 with event: NSEvent) {
        guard let surface = surface else { return }
        sendMousePos(event)
        _ = ghostty_surface_mouse_button(surface, state, button, event.ghosttyMouseMods)
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil))
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        sendMousePos(event)
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    override public func mouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, with: event)
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    override public func mouseMoved(with event: NSEvent) {
        sendMousePos(event)
    }

    override public func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, with: event)
        
        let targetMenu: NSMenu?
        if let custom = menuBuilder {
            targetMenu = custom(self, event)
        } else {
            targetMenu = self.menu(for: event)
        }
        
        if let targetMenu {
            NSMenu.popUpContextMenu(targetMenu, with: event, for: self)
        }
        
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, with: event)
    }

    override public func rightMouseUp(with event: NSEvent) {
        // Handled in rightMouseDown.
    }

    override public func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        
        let copyItem = NSMenuItem(
            title: String(localized: "Copy"),
            action: #selector(copyAction(_:)),
            keyEquivalent: "c"
        )
        copyItem.target = self
        copyItem.isEnabled = selectedText != nil
        menu.addItem(copyItem)
        
        let searchItem = NSMenuItem(
            title: String(localized: "Search with Google"),
            action: #selector(searchWithGoogleAction(_:)),
            keyEquivalent: ""
        )
        searchItem.target = self
        searchItem.isEnabled = selectedText != nil
        menu.addItem(searchItem)
        
        let pasteItem = NSMenuItem(
            title: String(localized: "Paste"),
            action: #selector(pasteAction(_:)),
            keyEquivalent: "v"
        )
        pasteItem.target = self
        menu.addItem(pasteItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let servicesItem = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        let servicesSubmenu = NSMenu()
        NSApp.servicesMenu = servicesSubmenu
        servicesItem.submenu = servicesSubmenu
        menu.addItem(servicesItem)
        
        return menu
    }
    
    public func resetTerminal() {
        guard let surface = surface else { return }
        let resetSeq = "\u{001B}c"
        resetSeq.withCString { cStr in
            ghostty_surface_text(surface, cStr, UInt(resetSeq.utf8.count))
        }
    }

    public func writeText(_ text: String) {
        guard let surface = surface else { return }
        text.withCString { cStr in
            ghostty_surface_text(surface, cStr, UInt(text.utf8.count))
        }
    }
    
    @objc public func searchWithGoogleAction(_ sender: Any) {
        guard let selectedText = self.selectedText,
              let encoded = selectedText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
    
    @objc public func copyAction(_ sender: Any) {
        guard let selectedText = self.selectedText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }
    
    @objc public func pasteAction(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string) {
            writeText(text)
        }
    }

    override public func otherMouseDown(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, with: event)
    }

    override public func otherMouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, with: event)
    }

    override public func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }

        // First tell Ghostty where the mouse is so it can resolve the correct surface
        let loc = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, loc.x, bounds.height - loc.y,
                                  ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue))

        // Build scroll mods:
        //   bit 0 = precision_scroll (trackpad / smooth scroll events)
        //   bit 1 = momentum_scroll  (kinetic deceleration phase)
        //   bit 2 = begin            (gesture began)
        //   bit 3 = end              (gesture ended)
        var scrollMods: Int32 = 0

        let isPrecise = event.hasPreciseScrollingDeltas
        if isPrecise { scrollMods |= 1 }

        // A non-empty momentumPhase means we are in the kinetic deceleration phase.
        let hasMomentum = event.momentumPhase != []
        if hasMomentum { scrollMods |= 2 }

        if event.phase == .began { scrollMods |= 1 << 2 }
        if event.phase == .ended || event.phase == .cancelled { scrollMods |= 1 << 3 }

        // Reduce tiny jitter during .mayBegin to better match NSScrollView feel
        if event.phase == .mayBegin {
            let threshold: CGFloat = 0.5
            if abs(event.scrollingDeltaX) < threshold && abs(event.scrollingDeltaY) < threshold {
                return
            }
        }

        // macOS scrollingDeltaY is already adjusted for the "Natural Scrolling"
        // preference, so pass it directly. Ghostty's Y axis is positive-up
        // (same convention as macOS), so no negation needed.
        let deltaX = event.scrollingDeltaX
        let deltaY: CGFloat
        if isPrecise {
            deltaY = event.scrollingDeltaY
        } else {
            let lineScale: CGFloat = 10.0
            deltaY = (event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY) * lineScale
        }

        ghostty_surface_mouse_scroll(surface,
                                     deltaX,
                                     deltaY,
                                     scrollMods)
    }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func setupSurfaceIfPossible() {
        guard let app = runtime.app else { return }
        var config = ghostty_surface_config_new()

        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? Self.fallbackBackingScaleFactor
        config.scale_factor = Double(scale)
        config.font_size = max(10.0, surfaceConfig.fontSize)
        config.wait_after_command = surfaceConfig.waitAfterCommand
        config.context = surfaceConfig.context

        let workingDirectory = surfaceConfig.workingDirectory
        let command = surfaceConfig.command
        let initialInput = surfaceConfig.initialInput

        var envVars = surfaceConfig.environmentVariables.map { key, value in
            ghostty_env_var_s(key: strdup(key), value: strdup(value))
        }

        // Bind the three optional C strings (each valid only within its closure)
        // then create the surface. This collapses the previous 8-way branch into
        // a single nested binding that scales with the optionals.
        Self.withOptionalCString(workingDirectory) { wd in
            Self.withOptionalCString(command) { cmd in
                Self.withOptionalCString(initialInput) { input in
                    if let wd { config.working_directory = wd }
                    if let cmd { config.command = cmd }
                    if let input { config.initial_input = input }
                    envVars.withUnsafeMutableBufferPointer { buffer in
                        config.env_vars = buffer.baseAddress
                        config.env_var_count = buffer.count
                        self.surface = ghostty_surface_new(app, &config)
                    }
                }
            }
        }

        for env in envVars {
            if let key = env.key { free(UnsafeMutableRawPointer(mutating: key)) }
            if let value = env.value { free(UnsafeMutableRawPointer(mutating: value)) }
        }

        // Register for cross-thread C callbacks only once a surface exists.
        if surface != nil {
            runtime.registerSurfaceView(self, forKey: registryKey)
        }
    }

    /// Invokes `body` with a C string pointer for `string`, or `nil` when the
    /// string is absent. The pointer is valid only for the duration of `body`.
    private static func withOptionalCString(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> Void
    ) {
        if let string {
            string.withCString { body($0) }
        } else {
            body(nil)
        }
    }

    private func updateContentScale() {
        guard let surface = surface else { return }
        let backingFrame = convertToBacking(bounds)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let xScale = backingFrame.width / bounds.width
        let yScale = backingFrame.height / bounds.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)
    }

    private func updateSurfaceSize() {
        guard let surface = surface else { return }
        let size = convertToBacking(bounds.size)
        guard size.width > 0, size.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    public func applyTheme(_ theme: GhosttyThemeDefinition) {
        guard let surface = surface else { return }
        
        var configLines: [String] = []
        configLines.append("background = \(theme.background)")
        configLines.append("foreground = \(theme.foreground)")
        if let cursorColor = theme.cursorColor {
            configLines.append("cursor-color = \(cursorColor)")
        }
        if let cursorText = theme.cursorText {
            configLines.append("cursor-text = \(cursorText)")
        }
        if let selectionBackground = theme.selectionBackground {
            configLines.append("selection-background = \(selectionBackground)")
        }
        if let selectionForeground = theme.selectionForeground {
            configLines.append("selection-foreground = \(selectionForeground)")
        }
        for index in theme.palette.keys.sorted() {
            if let color = theme.palette[index] {
                configLines.append("palette = \(index)=\(color)")
            }
        }
        
        let configContents = configLines.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-theme-\(UUID().uuidString)")
            .appendingPathExtension("conf")
            
        do {
            try configContents.write(to: url, atomically: true, encoding: .utf8)
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            
            if let nextConfig = ghostty_config_new() {
                ghostty_config_load_file(nextConfig, url.path)
                ghostty_config_finalize(nextConfig)
                ghostty_surface_update_config(surface, nextConfig)
                ghostty_config_free(nextConfig)
            }
        } catch {
            NSLog("Failed to write theme configuration: \(error)")
        }
    }
}

public struct GhosttySurfaceConfiguration: Sendable {
    public var fontSize: Float = 0
    public var workingDirectory: String?
    public var command: String?
    public var environmentVariables: [String: String] = [:]
    public var initialInput: String?
    public var waitAfterCommand: Bool = false
    public var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW

    public init(
        fontSize: Float = 0,
        workingDirectory: String? = nil,
        command: String? = nil,
        environmentVariables: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW
    ) {
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory
        self.command = command
        self.environmentVariables = environmentVariables
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.context = context
    }
}

// MARK: - NSTextInputClient Implementation
extension GhosttySurfaceView {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        if isReadOnly { return }
        guard let surface = surface else { return }
        let text: String
        if let attrStr = string as? NSAttributedString {
            text = attrStr.string
        } else if let str = string as? String {
            text = str
        } else {
            return
        }
        
        self.markedText = nil
        ghostty_surface_preedit(surface, nil, 0)
        
        if accumulatedTexts != nil {
            accumulatedTexts?.append(text)
        } else {
            text.withCString { cStr in
                ghostty_surface_text(surface, cStr, UInt(text.utf8.count))
            }
        }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    
    public func setMarkedText(_ markedText: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let surface = surface else { return }
        let text: String
        if let attrStr = markedText as? NSAttributedString {
            text = attrStr.string
        } else if let str = markedText as? String {
            text = str
        } else {
            return
        }
        
        if text.isEmpty {
            self.unmarkText()
            return
        }
        
        self.markedText = text
        text.withCString { cStr in
            ghostty_surface_preedit(surface, cStr, UInt(text.utf8.count))
        }
    }
    
    public func unmarkText() {
        guard let surface = surface else { return }
        self.markedText = nil
        ghostty_surface_preedit(surface, nil, 0)
    }
    
    public func hasMarkedText() -> Bool {
        return markedText != nil
    }
    
    public func markedRange() -> NSRange {
        if let text = markedText {
            return NSRange(location: 0, length: text.utf16.count)
        }
        return NSRange(location: NSNotFound, length: 0)
    }
    
    public var selectedText: String? {
        guard let surface = surface else { return nil }
        guard ghostty_surface_has_selection(surface) else { return nil }
        var textStruct = ghostty_text_s()
        if ghostty_surface_read_selection(surface, &textStruct) {
            defer {
                ghostty_surface_free_text(surface, &textStruct)
            }
            if let textPtr = textStruct.text {
                return String(bytes: UnsafeRawBufferPointer(start: textPtr, count: Int(textStruct.text_len)), encoding: .utf8)
            }
        }
        return nil
    }

    public func selectedRange() -> NSRange {
        if let selectedText = self.selectedText {
            return NSRange(location: 0, length: selectedText.utf16.count)
        }
        return NSRange(location: NSNotFound, length: 0)
    }
    
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }
    
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let selectedText = self.selectedText else { return nil }
        let nsStr = selectedText as NSString
        let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: nsStr.length))
        if safeRange.length > 0 {
            let sub = nsStr.substring(with: safeRange)
            return NSAttributedString(string: sub)
        }
        return nil
    }
    
    public func characterIndex(for point: NSPoint) -> Int {
        return NSNotFound
    }
    
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = surface else { return .zero }
        
        let scale = self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? Self.fallbackBackingScaleFactor
        
        // If we have selected text, return the selection's physical top-left converted to screen coordinates.
        var textStruct = ghostty_text_s()
        if ghostty_surface_read_selection(surface, &textStruct) {
            defer {
                ghostty_surface_free_text(surface, &textStruct)
            }
            let logicalX = CGFloat(textStruct.tl_px_x) / scale
            let textHeight = CGFloat(surfaceConfig.fontSize > 0 ? surfaceConfig.fontSize : 14)
            let logicalY = bounds.height - (CGFloat(textStruct.tl_px_y) / scale) - textHeight
            
            let rectInView = NSRect(x: logicalX, y: logicalY, width: 100, height: textHeight)
            let rectInWindow = self.convert(rectInView, to: nil)
            return self.window?.convertToScreen(rectInWindow) ?? .zero
        }
        
        // Otherwise fallback to the IME cursor point.
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        
        let logicalW = CGFloat(w) / scale
        let logicalH = CGFloat(h) / scale
        
        // ghostty y-coordinate is y-down (from top of viewport)
        let logicalX = CGFloat(x) / scale
        let logicalY = bounds.height - (CGFloat(y) / scale) - logicalH
        
        let rectInView = NSRect(x: logicalX, y: logicalY, width: logicalW, height: logicalH)
        
        let rectInWindow = self.convert(rectInView, to: nil)
        let rectInScreen = self.window?.convertToScreen(rectInWindow) ?? .zero
        return rectInScreen
    }
}
