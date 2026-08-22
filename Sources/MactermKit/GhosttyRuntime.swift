import AppKit
import Foundation
import GhosttyKit
import MSDisplayLink

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
        runtime.setPendingTick()
    }
}

private func ghostty_read_clipboard_callback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    request: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata, let request else { return false }
    // Identify the surface view by its address rather than dereferencing the raw
    // pointer on the background thread. The view may be deallocated before this
    // async block runs, so we look it up through the runtime's weak registry on
    // the main thread to avoid a use-after-free.
    let viewAddress = Int(bitPattern: userdata)
    let requestAddress = Int(bitPattern: request)
    
    DispatchQueue.main.async {
        guard let reqPtr = UnsafeMutableRawPointer(bitPattern: requestAddress) else { return }
        
        // If the view (and therefore its surface) is gone, the request pointer is
        // no longer valid either, so we must not touch it.
        guard let surfaceView = GhosttyRuntime.shared.surfaceView(forKey: viewAddress),
              let surface = surfaceView.rawSurface else { return }
        
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string) {
            text.withCString { cStr in
                ghostty_surface_complete_clipboard_request(surface, cStr, reqPtr, true)
            }
        } else {
            ghostty_surface_complete_clipboard_request(surface, nil, reqPtr, false)
        }
    }
    return true
}

private func ghostty_confirm_read_clipboard_callback(
    userdata: UnsafeMutableRawPointer?,
    requestInfo: UnsafePointer<CChar>?,
    requestData: UnsafeMutableRawPointer?,
    requestKind: ghostty_clipboard_request_e
) {
    guard let userdata, let requestData else { return }
    let runtimeAddress = Int(bitPattern: userdata)
    let requestAddress = Int(bitPattern: requestData)
    
    DispatchQueue.main.async {
        guard let runtimePtr = UnsafeMutableRawPointer(bitPattern: runtimeAddress) else { return }
        guard let reqPtr = UnsafeMutableRawPointer(bitPattern: requestAddress) else { return }
        
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(runtimePtr).takeUnretainedValue()
        guard let surface = runtime.activeSurface else {
            ghostty_surface_complete_clipboard_request(nil, nil, reqPtr, false)
            return
        }
        
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Clipboard Read Request", comment: "")
        alert.informativeText = NSLocalizedString("A command-line program is requesting to read your clipboard. Do you want to allow this?", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Allow", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Deny", comment: ""))
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let pasteboard = NSPasteboard.general
            if let text = pasteboard.string(forType: .string) {
                text.withCString { cStr in
                    ghostty_surface_complete_clipboard_request(surface, cStr, reqPtr, true)
                }
            } else {
                ghostty_surface_complete_clipboard_request(surface, nil, reqPtr, false)
            }
        } else {
            ghostty_surface_complete_clipboard_request(surface, nil, reqPtr, false)
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
    
    // String is Sendable, so we copy it out on the calling background thread
    // before sending it to the MainActor
    var textToCopy: String? = nil
    for i in 0..<contentLen {
        let item = content[i]
        guard let mimePtr = item.mime, let dataPtr = item.data else { continue }
        let mime = String(cString: mimePtr)
        let data = String(cString: dataPtr)
        
        if mime == "text/plain" || mime.hasPrefix("text/") {
            textToCopy = data
            break
        }
    }
    
    guard let text = textToCopy else { return }
    
    DispatchQueue.main.async {
        // When the core requires confirmation (e.g. `clipboard-write = ask`),
        // defer the decision to the host application. If no handler is installed
        // we deny the write — never silently overwrite the user's clipboard on
        // behalf of a program (OSC 52 clipboard-hijack protection).
        if confirm {
            let approved = GhosttyRuntime.shared.clipboardWriteConfirmationHandler?(text) ?? false
            guard approved else { return }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Terminal events surfaced from Ghostty's action callback that a host app may
/// want to react to (e.g. system notifications).
public enum GhosttyTerminalEvent: Sendable {
    /// A program rang the terminal bell (BEL).
    case bell
    /// A program requested a desktop notification (OSC 9 / OSC 777).
    case desktopNotification(title: String, body: String)
    /// The surface's child process exited with the given code.
    case childExited(exitCode: UInt32)
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
    let event: GhosttyTerminalEvent
    switch action.tag {
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        let notification = action.action.desktop_notification
        event = .desktopNotification(
            title: notification.title.map { String(cString: $0) } ?? "",
            body: notification.body.map { String(cString: $0) } ?? ""
        )
    case GHOSTTY_ACTION_RING_BELL:
        event = .bell
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        event = .childExited(exitCode: action.action.child_exited.exit_code)
    default:
        return false
    }

    DispatchQueue.main.async {
        GhosttyRuntime.shared.onTerminalEvent?(event)
    }
    return true
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

    /// Weak registry of live surface views keyed by their pointer address, used
    /// to resolve C callbacks safely across threads without dereferencing a raw
    /// (potentially dangling) pointer.
    private var surfaceViews: [Int: WeakSurfaceView] = [:]
    
    private let displayLink = DisplayLink()
    private var pendingTick = false

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

    public func setPendingTick() {
        pendingTick = true
    }

    // MARK: - Surface view registry

    func registerSurfaceView(_ view: GhosttySurfaceView, forKey key: Int) {
        surfaceViews[key] = WeakSurfaceView(view)
    }

    func unregisterSurfaceView(forKey key: Int) {
        surfaceViews.removeValue(forKey: key)
    }

    func surfaceView(forKey key: Int) -> GhosttySurfaceView? {
        surfaceViews[key]?.value
    }

    nonisolated public func synchronization(context: DisplayLinkCallbackContext) {
        Task { @MainActor in
            if pendingTick {
                pendingTick = false
                appTick()
            }
        }
    }

    public func appTick() {
        guard let app = app else { return }
        ghostty_app_tick(app)
    }
}
