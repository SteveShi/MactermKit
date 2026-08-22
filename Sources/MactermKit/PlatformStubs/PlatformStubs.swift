import SwiftUI

#if canImport(UIKit)
import UIKit

@MainActor
public class UITerminalView: UIView {
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
#endif

#if os(macOS)
public typealias TerminalViewPlatformBase = GhosttySurfaceView
#elseif os(iOS)
public typealias TerminalViewPlatformBase = UITerminalView
#endif

#if os(macOS)
@MainActor
public struct TerminalViewRepresentable: NSViewRepresentable {
    public let configuration: GhosttySurfaceConfiguration

    public init(configuration: GhosttySurfaceConfiguration) {
        self.configuration = configuration
    }

    public func makeNSView(context: Context) -> GhosttySurfaceView {
        return GhosttySurfaceView(config: configuration)
    }

    public func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {}
}
#elseif os(iOS)
@MainActor
public struct TerminalViewRepresentable: UIViewRepresentable {
    public let configuration: GhosttySurfaceConfiguration

    public init(configuration: GhosttySurfaceConfiguration) {
        self.configuration = configuration
    }

    public func makeUIView(context: Context) -> UITerminalView {
        return UITerminalView(frame: .zero)
    }

    public func updateUIView(_ uiView: UITerminalView, context: Context) {}
}
#endif
