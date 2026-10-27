import AppKit
import Foundation
import UniformTypeIdentifiers
import MactermKitCore
import MSDisplayLink

private extension NSWorkspace {
    func defaultApplicationURL(forExtension ext: String) -> URL? {
        guard let uti = UTType(filenameExtension: ext) else { return nil }
        return urlForApplication(toOpen: uti)
    }

    func defaultApplicationURL(for utType: UTType) -> URL? {
        urlForApplication(toOpen: utType)
    }
}

// Use a top-level function for the C callback to ensure NO implicit actor isolation.
// This is critical because this function is called from Ghostty's background renderer thread.
private func ghostty_wakeup_callback(userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    
    // Convert the pointer to an Int (bit pattern). Int is Sendable, 
    // which allows it to cross from the background thread to the MainActor 
    // without triggering Swift 6's data race detection for UnsafeMutableRawPointer.
    let bitPattern = Int(bitPattern: userdata)
    
    DispatchQueue.main.async {
        // Re-construct the pointer from the bit pattern on the main thread.
        guard let opaque = UnsafeMutableRawPointer(bitPattern: bitPattern) else { return }
        
        // Now on the main thread, we can safely re-acquire the GhosttyRuntime (which is @MainActor)
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(opaque).takeUnretainedValue()
        runtime.appTick()
    }
}

private func getPasteboardString() -> String? {
    let pasteboard = NSPasteboard.general
    if let text = pasteboard.string(forType: .string) {
        return text
    }
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
        return urls.map { $0.path }.joined(separator: " ")
    }
    return nil
}

private func completeClipboardRequest(
    surface: ghostty_surface_t,
    statePtr: UnsafeMutableRawPointer,
    contents: [(mime: String, data: Data)],
    available: [String],
    confirmed: Bool,
    remember: Bool
) {
    let availableCStrings = available.map { strdup($0) }
    defer {
        for ptr in availableCStrings {
            if let ptr { free(ptr) }
        }
    }
    let availPtrs: [UnsafePointer<CChar>?] = availableCStrings.map { $0.map { UnsafePointer($0) } }

    let nsDatas = contents.map { $0.data as NSData }
    let mimeCStrings = contents.map { strdup($0.mime) }
    defer {
        for ptr in mimeCStrings {
            if let ptr { free(ptr) }
        }
    }

    var cContents: [ghostty_clipboard_content_s] = []
    for (i, item) in contents.enumerated() {
        let mimePtr = mimeCStrings[i]
        let nsData = nsDatas[i]
        let bytesPtr = nsData.bytes.assumingMemoryBound(to: CChar.self)
        cContents.append(ghostty_clipboard_content_s(
            mime: mimePtr,
            data: bytesPtr,
            len: item.data.count
        ))
    }

    cContents.withUnsafeBufferPointer { cContentsBuf in
        availPtrs.withUnsafeBufferPointer { availBuf in
            var complete = ghostty_clipboard_complete_s(
                contents: cContentsBuf.isEmpty ? nil : cContentsBuf.baseAddress,
                contents_len: cContentsBuf.count,
                available: availBuf.isEmpty ? nil : availBuf.baseAddress,
                available_len: availBuf.count,
                confirmed: confirmed,
                remember: remember
            )
            ghostty_surface_complete_clipboard_request(surface, &complete, statePtr)
        }
    }
}

private func ghostty_read_clipboard_callback(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLen: Int,
    list: Bool
) -> ghostty_clipboard_read_result_e {
    guard let userdata, let state else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
    let viewAddress = Int(bitPattern: userdata)
    let stateAddress = Int(bitPattern: state)

    var requestedMimes: [String] = []
    if let mimes, mimesLen > 0 {
        for i in 0..<mimesLen {
            if let cStr = mimes[i] {
                requestedMimes.append(String(cString: cStr))
            }
        }
    }
    if requestedMimes.isEmpty && !list {
        requestedMimes = ["text/plain"]
    }

    DispatchQueue.main.async {
        guard let statePtr = UnsafeMutableRawPointer(bitPattern: stateAddress) else { return }
        guard let surfaceView = GhosttyRuntime.shared.surfaceView(forKey: viewAddress) ??
                                GhosttyRuntime.shared.surfaceView(forHandleKey: viewAddress),
              let surface = surfaceView.rawSurface ?? GhosttyRuntime.shared.activeSurface else {
            return
        }

        let pasteboard = NSPasteboard.general
        var servedContents: [(mime: String, data: Data)] = []
        for mime in requestedMimes {
            if mime == "text/plain" || mime.hasPrefix("text/") {
                if let text = getPasteboardString(), let data = text.data(using: .utf8) {
                    servedContents.append((mime: "text/plain", data: data))
                }
            } else if mime == "text/html" {
                if let data = pasteboard.data(forType: .html) {
                    servedContents.append((mime: "text/html", data: data))
                }
            } else if mime == "image/png" {
                if let data = pasteboard.data(forType: .png) {
                    servedContents.append((mime: "image/png", data: data))
                }
            }
        }

        var availableMimes: [String] = []
        if list {
            if pasteboard.string(forType: .string) != nil || pasteboard.string(forType: .fileURL) != nil || pasteboard.string(forType: .URL) != nil {
                availableMimes.append("text/plain")
            }
            if pasteboard.data(forType: .html) != nil {
                availableMimes.append("text/html")
            }
            if pasteboard.data(forType: .png) != nil {
                availableMimes.append("image/png")
            }
            if pasteboard.data(forType: .tiff) != nil {
                availableMimes.append("image/tiff")
            }
        }

        completeClipboardRequest(
            surface: surface,
            statePtr: statePtr,
            contents: servedContents,
            available: availableMimes,
            confirmed: false, // Must be false to trigger Ghostty's safety checks!
            remember: false
        )
    }
    return GHOSTTY_CLIPBOARD_READ_STARTED
}

private func ghostty_confirm_read_clipboard_callback(
    userdata: UnsafeMutableRawPointer?,
    confirmPtr: UnsafePointer<ghostty_clipboard_confirm_s>?,
    state: UnsafeMutableRawPointer?,
    requestKind: ghostty_clipboard_request_e
) {
    guard let userdata, let state else { return }
    let viewAddress = Int(bitPattern: userdata)
    let stateAddress = Int(bitPattern: state)

    var copiedContents: [(mime: String, data: Data)] = []
    var copiedAvailable: [String] = []
    var programName: String? = nil
    var canRemember: Bool = false

    if let confirm = confirmPtr?.pointee {
        if let contents = confirm.contents, confirm.contents_len > 0 {
            for i in 0..<confirm.contents_len {
                let item = contents[i]
                let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
                let data: Data
                if let dataPtr = item.data, item.len > 0 {
                    data = Data(bytes: dataPtr, count: item.len)
                } else {
                    data = Data()
                }
                copiedContents.append((mime: mime, data: data))
            }
        }
        if let avail = confirm.available, confirm.available_len > 0 {
            for i in 0..<confirm.available_len {
                if let cStr = avail[i] {
                    copiedAvailable.append(String(cString: cStr))
                }
            }
        }
        if let namePtr = confirm.name {
            programName = String(cString: namePtr)
        }
        canRemember = confirm.can_remember
    }

    DispatchQueue.main.async {
        guard let statePtr = UnsafeMutableRawPointer(bitPattern: stateAddress) else { return }
        guard let surfaceView = GhosttyRuntime.shared.surfaceView(forKey: viewAddress) ??
                                GhosttyRuntime.shared.surfaceView(forHandleKey: viewAddress),
              let surface = surfaceView.rawSurface ?? GhosttyRuntime.shared.activeSurface else {
            return
        }

        let alert = NSAlert()
        switch requestKind {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            alert.messageText = NSLocalizedString("Unsafe Paste Warning", comment: "")
            alert.informativeText = NSLocalizedString("The text you are pasting contains newlines or carriage returns that may execute commands immediately. Do you want to paste anyway?", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Paste", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        default:
            let prog = programName ?? NSLocalizedString("A command-line program", comment: "")
            alert.messageText = NSLocalizedString("Clipboard Access Request", comment: "")
            alert.informativeText = String(format: NSLocalizedString("%@ is requesting to read your clipboard. Do you want to allow this?", comment: ""), prog)
            alert.addButton(withTitle: NSLocalizedString("Allow", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Deny", comment: ""))
        }

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            var finalContents = copiedContents
            if finalContents.isEmpty {
                if let text = getPasteboardString(), let data = text.data(using: .utf8) {
                    finalContents = [(mime: "text/plain", data: data)]
                }
            }
            completeClipboardRequest(
                surface: surface,
                statePtr: statePtr,
                contents: finalContents,
                available: copiedAvailable,
                confirmed: true,
                remember: canRemember
            )
        } else {
            ghostty_surface_deny_clipboard_request(surface, statePtr)
        }
    }
}

private func ghostty_write_clipboard_callback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    contentLen: Int,
    confirm: Bool
) {
    guard let content, contentLen > 0 else { return }
    
    // Bound each clipboard item to at most 16 MiB
    let maxClipboardItemBytes = 16 * 1024 * 1024
    
    // String and Data are Sendable, so we copy them out on the calling background thread
    // before sending to the MainActor
    var textToCopy: String? = nil
    var htmlDataToCopy: Data? = nil
    var pngDataToCopy: Data? = nil

    for i in 0..<contentLen {
        let item = content[i]
        guard let dataPtr = item.data, item.len > 0, item.len <= maxClipboardItemBytes else { continue }
        let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
        let data = Data(bytes: dataPtr, count: item.len)
        if mime == "text/html" {
            if htmlDataToCopy == nil {
                htmlDataToCopy = data
            }
        } else if mime == "image/png" {
            if pngDataToCopy == nil {
                pngDataToCopy = data
            }
        } else if mime == "text/plain" || mime.hasPrefix("text/plain;") {
            if textToCopy == nil, let str = String(data: data, encoding: .utf8) {
                textToCopy = str
            }
        }
    }
    
    if textToCopy == nil && htmlDataToCopy == nil && pngDataToCopy == nil {
        return
    }
    
    DispatchQueue.main.async {
        // When the core requires confirmation (e.g. `clipboard-write = ask`),
        // defer the decision to the host application. If no handler is installed
        // we deny the write — never silently overwrite the user's clipboard on
        // behalf of a program (OSC 52 clipboard-hijack protection).
        if confirm {
            guard let text = textToCopy,
                  GhosttyRuntime.shared.clipboardWriteConfirmationHandler?(text) == true else {
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let text = textToCopy {
            pasteboard.setString(text, forType: .string)
        }
        if let htmlData = htmlDataToCopy {
            pasteboard.setData(htmlData, forType: .html)
        }
        if let pngData = pngDataToCopy {
            pasteboard.setData(pngData, forType: .png)
        }
    }
}

/// Program status report state (OSC 7501).
public enum GhosttyProgramStatusState: Int, Sendable, Equatable {
    case idle = 0
    case working = 1
    case done = 2
    case blocked = 3
    case error = 4
    case clear = 5
}

/// Program status report kind (OSC 7501).
public enum GhosttyProgramStatusKind: Int, Sendable, Equatable {
    case none = -1
    case permission = 0
    case question = 1
    case auth = 2
}

/// Detailed Program Status Report (OSC 7501).
public struct GhosttyProgramStatusReport: Sendable, Equatable {
    public let state: GhosttyProgramStatusState
    public let kind: GhosttyProgramStatusKind
    public let progress: Int16
    public let id: String
    public let app: String
    public let title: String
    public let message: String

    public init(
        state: GhosttyProgramStatusState,
        kind: GhosttyProgramStatusKind,
        progress: Int16,
        id: String,
        app: String,
        title: String,
        message: String
    ) {
        self.state = state
        self.kind = kind
        self.progress = progress
        self.id = id
        self.app = app
        self.title = title
        self.message = message
    }
}

/// Progress report state (ConEmu OSC 9;4).
public enum GhosttyProgressReportState: Int, Sendable, Equatable {
    case remove = 0
    case set = 1
    case error = 2
    case indeterminate = 3
    case pause = 4
}

/// ConEmu OSC 9;4 progress report.
public struct GhosttyProgressReport: Sendable, Equatable {
    public let state: GhosttyProgressReportState
    public let progress: Int8

    public init(state: GhosttyProgressReportState, progress: Int8) {
        self.state = state
        self.progress = progress
    }
}

/// Terminal events surfaced from Ghostty's action callback that a host app may
/// want to react to (e.g. system notifications, CWD updates, title changes).
public enum GhosttyTerminalEvent: Sendable, Equatable {
    /// A program rang the terminal bell (BEL).
    case bell
    /// A program requested a desktop notification (OSC 9 / OSC 777).
    case desktopNotification(title: String, body: String)
    /// The surface's child process exited with the given code.
    case childExited(exitCode: UInt32)
    /// The current working directory changed (OSC 7).
    case currentDirectoryChanged(url: String)
    /// The terminal window title changed (OSC 0 / OSC 2).
    case titleChanged(title: String)
    /// The terminal tab title changed.
    case tabTitleChanged(title: String)
    /// A command finished executing (OSC 133 D).
    case commandFinished(exitCode: Int16, durationNs: UInt64)
    /// Program status report updated (OSC 7501).
    case programStatus(GhosttyProgramStatusReport)
    /// Progress report updated (ConEmu OSC 9;4).
    case progressReport(GhosttyProgressReport)
    /// Pointer hovered over or exited a link.
    case hoverLink(String?)
}

/// Top-level C action callback (no actor isolation — may be invoked from
/// Ghostty's app tick). Relevant actions are translated to a `Sendable`
/// `GhosttyTerminalEvent` and delivered on the main thread; all other actions
/// keep the previous no-op behavior (`return false`).
private func ghostty_action_callback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    var targetSurfaceKey: Int? = nil
    if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
        targetSurfaceKey = Int(bitPattern: surface)
    }

    switch action.tag {
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        let notification = action.action.desktop_notification
        let event = GhosttyTerminalEvent.desktopNotification(
            title: notification.title.map { String(cString: $0) } ?? "",
            body: notification.body.map { String(cString: $0) } ?? ""
        )
        dispatchTerminalEvent(event, targetSurfaceKey: targetSurfaceKey)
        return true

    case GHOSTTY_ACTION_RING_BELL:
        dispatchTerminalEvent(.bell, targetSurfaceKey: targetSurfaceKey)
        return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        let event = GhosttyTerminalEvent.childExited(exitCode: action.action.child_exited.exit_code)
        dispatchTerminalEvent(event, targetSurfaceKey: targetSurfaceKey)
        return true

    case GHOSTTY_ACTION_PWD:
        let pwd = action.action.pwd.pwd.map { String(cString: $0) } ?? ""
        dispatchTerminalEvent(.currentDirectoryChanged(url: pwd), targetSurfaceKey: targetSurfaceKey)
        return true

    case GHOSTTY_ACTION_SET_TITLE:
        let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
        dispatchTerminalEvent(.titleChanged(title: title), targetSurfaceKey: targetSurfaceKey)
        return true

    case GHOSTTY_ACTION_SET_TAB_TITLE:
        let title = action.action.set_tab_title.title.map { String(cString: $0) } ?? ""
        dispatchTerminalEvent(.tabTitleChanged(title: title), targetSurfaceKey: targetSurfaceKey)
        return true

    case GHOSTTY_ACTION_COMMAND_FINISHED:
        let finished = action.action.command_finished
        let event = GhosttyTerminalEvent.commandFinished(exitCode: finished.exit_code, durationNs: finished.duration)
        dispatchTerminalEvent(event, targetSurfaceKey: targetSurfaceKey)
        return true

    case GHOSTTY_ACTION_PROGRAM_STATUS:
        guard let reportPtr = action.action.program_status.report else { return false }
        let r = reportPtr.pointee
        let report = GhosttyProgramStatusReport(
            state: GhosttyProgramStatusState(rawValue: Int(r.state.rawValue)) ?? .idle,
            kind: GhosttyProgramStatusKind(rawValue: Int(r.kind.rawValue)) ?? .none,
            progress: r.progress,
            id: r.id.map { String(cString: $0) } ?? "",
            app: r.app.map { String(cString: $0) } ?? "",
            title: r.title.map { String(cString: $0) } ?? "",
            message: r.msg.map { String(cString: $0) } ?? ""
        )
        dispatchTerminalEvent(.programStatus(report), targetSurfaceKey: targetSurfaceKey)
        return true

    case GHOSTTY_ACTION_PROGRESS_REPORT:
        let p = action.action.progress_report
        let report = GhosttyProgressReport(
            state: GhosttyProgressReportState(rawValue: Int(p.state.rawValue)) ?? .remove,
            progress: p.progress
        )
        dispatchTerminalEvent(.progressReport(report), targetSurfaceKey: targetSurfaceKey)
        return true

    case GHOSTTY_ACTION_MOUSE_SHAPE:
        let shape = action.action.mouse_shape
        DispatchQueue.main.async {
            if let targetSurfaceKey, let view = GhosttyRuntime.shared.surfaceView(forHandleKey: targetSurfaceKey) {
                view.applyMouseShape(shape)
            }
        }
        return true

    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
        let linkAction = action.action.mouse_over_link
        let urlStr: String?
        if let urlPtr = linkAction.url, linkAction.len > 0 {
            urlStr = String(bytes: UnsafeRawBufferPointer(start: urlPtr, count: linkAction.len), encoding: .utf8)
        } else {
            urlStr = nil
        }
        dispatchTerminalEvent(.hoverLink(urlStr), targetSurfaceKey: targetSurfaceKey)
        return true

    case GHOSTTY_ACTION_OPEN_URL:
        let openUrl = action.action.open_url
        guard let urlPtr = openUrl.url, openUrl.len > 0,
              let urlStr = String(bytes: UnsafeRawBufferPointer(start: urlPtr, count: Int(openUrl.len)), encoding: .utf8) else {
            return true
        }

        // Reject any URL containing ASCII control characters
        guard !urlStr.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return true
        }

        guard let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(),
              url.user == nil,
              url.password == nil else {
            return true
        }

        switch scheme {
        case "http", "https", "mailto":
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
            return true

        case "file":
            // Only allow plain-text auto-detected URLs, never OSC 8 or unknown kinds
            guard openUrl.kind == GHOSTTY_ACTION_OPEN_URL_KIND_TEXT else { return true }
            DispatchQueue.main.async {
                if let textEditor = NSWorkspace.shared.defaultApplicationURL(forExtension: url.pathExtension)
                    ?? NSWorkspace.shared.defaultApplicationURL(for: .plainText) {
                    NSWorkspace.shared.open([url], withApplicationAt: textEditor, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            return true

        default:
            return true
        }

    default:
        return false
    }
}

private func dispatchTerminalEvent(_ event: GhosttyTerminalEvent, targetSurfaceKey: Int?) {
    DispatchQueue.main.async {
        if let targetSurfaceKey, let view = GhosttyRuntime.shared.surfaceView(forHandleKey: targetSurfaceKey) {
            view.onEvent?(event)
        }
        GhosttyRuntime.shared.onTerminalEvent?(event)
    }
}

/// Weak wrapper so the runtime registry never extends a surface view's lifetime.
private final class WeakSurfaceView {
    weak var value: GhosttySurfaceView?
    init(_ value: GhosttySurfaceView) { self.value = value }
}

@MainActor
public final class GhosttyRuntime: DisplayLinkDelegate {
    public static let shared = GhosttyRuntime()

    public private(set) var app: ghostty_app_t?
    public private(set) var config: ghostty_config_t?
    public var activeSurface: ghostty_surface_t?

    /// Invoked when a program requests to write the system clipboard and the
    /// configuration requires confirmation. Return `true` to allow the write.
    /// If no handler is installed, confirmation-required writes are denied.
    public var clipboardWriteConfirmationHandler: ((String) -> Bool)?

    /// Invoked on the main thread when a terminal surface emits a notable event
    /// (bell, app-requested desktop notification, child process exit).
    public var onTerminalEvent: ((GhosttyTerminalEvent) -> Void)?

    /// Invoked on the main thread when a terminal surface gains first-responder focus.
    public var onSurfaceFocused: (() -> Void)?

    /// Invoked on the main thread when a terminal surface resigns first-responder focus.
    public var onSurfaceResigned: (() -> Void)?

    /// Weak registry of live surface views keyed by their pointer address, used
    /// to resolve C callbacks safely across threads without dereferencing a raw
    /// (potentially dangling) pointer.
    private var surfaceViews: [Int: WeakSurfaceView] = [:]
    
    private let displayLink = DisplayLink()

    private init() {
        _ = ghostty_init(0, nil)

        let cfg = ghostty_config_new()
        if let cfg {
            ghostty_config_load_default_files(cfg)
            ghostty_config_finalize(cfg)
        }
        self.config = cfg

        // ghostty_runtime_config_s members are @convention(c)
        var runtimeCfg = ghostty_runtime_config_s()
        runtimeCfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeCfg.supports_selection_clipboard = true
        runtimeCfg.wakeup_cb = ghostty_wakeup_callback
        
        // Use empty closures for other callbacks to avoid any potential isolation issues in inline closures
        runtimeCfg.action_cb = ghostty_action_callback
        runtimeCfg.read_clipboard_cb = ghostty_read_clipboard_callback
        runtimeCfg.confirm_read_clipboard_cb = ghostty_confirm_read_clipboard_callback
        runtimeCfg.write_clipboard_cb = ghostty_write_clipboard_callback
        runtimeCfg.close_surface_cb = { _, _ in }

        if let cfg {
            self.app = ghostty_app_new(&runtimeCfg, cfg)
        }
        
        displayLink.delegatingObject(self)
    }

    /// Sets the color scheme (light or dark) across all surfaces of the Ghostty app.
    public func setColorScheme(isDark: Bool) {
        guard let app = app else { return }
        ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    public func setPendingTick() {
        appTick()
    }

    // MARK: - Surface view registry

    private var surfaceHandles: [Int: WeakSurfaceView] = [:]

    func registerSurfaceView(_ view: GhosttySurfaceView, forKey key: Int) {
        surfaceViews[key] = WeakSurfaceView(view)
    }

    func unregisterSurfaceView(forKey key: Int) {
        surfaceViews.removeValue(forKey: key)
    }

    func surfaceView(forKey key: Int) -> GhosttySurfaceView? {
        surfaceViews[key]?.value
    }

    func registerSurfaceHandle(_ handle: ghostty_surface_t, forView view: GhosttySurfaceView) {
        let key = Int(bitPattern: handle)
        surfaceHandles[key] = WeakSurfaceView(view)
    }

    func unregisterSurfaceHandle(_ handle: ghostty_surface_t) {
        let key = Int(bitPattern: handle)
        surfaceHandles.removeValue(forKey: key)
    }

    func surfaceView(forHandleKey key: Int) -> GhosttySurfaceView? {
        surfaceHandles[key]?.value
    }

    nonisolated public func synchronization(context: DisplayLinkCallbackContext) {
        Task { @MainActor in
            appTick()
        }
    }

    public func appTick() {
        guard let app = app else { return }
        ghostty_app_tick(app)
    }
}
