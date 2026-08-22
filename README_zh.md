# MactermKit 中文文档

[English](README.md)

`MactermKit` 是一个高内聚的 **Ghostty 终端模拟与渲染核心** 的 Swift Package 封装包。

它解耦了原生的终端仿真实现，提供了平滑的渲染更新、中文输入法（IME）原生支持、配色主题扩展，并完全兼容 Swift 6 的并发安全规范。

---

## 核心特点

1. **跨平台兼容设计 (Stubs)**：提供 SwiftUI 跨平台包装 `TerminalViewRepresentable`，并在 iOS 平台提供 `UITerminalView` 存根，方便后续跨平台演进。
2. **硬件高刷渲染同步**：集成 `MSDisplayLink`，当 Ghostty 触发 Wakeup 重绘请求时，延迟到屏幕垂直同步信号（VSYNC，如 120Hz）触发渲染，消除无意义的空转，大幅度降低 CPU 开销。
3. **配色主题集成 (GhosttyTheme)**：内置 Dracula, GitHub Dark, GitHub Light, Gruvbox Dark, Doom One 等精美主题，支持运行时动态（热更新）更新主题。
4. **Swift 6 并发安全**：全模块严格遵循 Swift 6 Concurrency 安全隔离规范，使用 `@MainActor` 隔离 UI 状态，消除数据竞争。
5. **沙盒化 Shell 模拟 (ShellCraftKit)**：保留沙盒内进程内 Shell 命令模拟执行 API 及存根，为未来扩展保留通道。

---

## 依赖关系

在您的 `Package.swift` 中引入：

```swift
dependencies: [
    .package(url: "https://github.com/SteveShi/MactermKit.git", from: "1.0.13")
]
```

并在相应的 Target 中依赖 `"MactermKit"`。

*注意：本库底层依赖 `GhosttyKit.xcframework` 二进制静态库。*

---

## 核心 API 与接口说明

### 1. `GhosttyRuntime`
终端全局环境运行时管理类。负责控制 Ghostty 的初始化、配置加载、生命周期及后台 wakeup 回调分发。

```swift
@MainActor
public final class GhosttyRuntime: DisplayLinkDelegate {
    /// 单例获取运行时
    public static let shared: GhosttyRuntime
    
    /// 底层 C App 句柄
    public private(set) var app: ghostty_app_t?
    
    /// 底层全局 C 配置
    public private(set) var config: ghostty_config_t?
    
    /// 标记存在未渲染的帧，供 DisplayLink 刷新消费
    public func setPendingTick()
    
    /// 触发单次底层 tick 逻辑
    public func appTick()
}
```

### 2. `GhosttySurfaceView`
终端渲染的视口 View (在 macOS 下继承自 `NSView`，并遵循 `NSTextInputClient` 协议)。

```swift
@MainActor
public class GhosttySurfaceView: NSView, NSTextInputClient {
    /// 关联的运行时实例
    public let runtime: GhosttyRuntime
    
    /// 底层 C Surface 句柄
    public var rawSurface: ghostty_surface_t? { get }
    
    /// 构造方法
    public init(runtime: GhosttyRuntime = .shared, config: GhosttySurfaceConfiguration = GhosttySurfaceConfiguration())
    
    /// 运行时动态应用新主题（热切换配色）
    public func applyTheme(_ theme: GhosttyThemeDefinition)
}
```

### 3. `GhosttySurfaceConfiguration`
用于初始化 `GhosttySurfaceView` 的配置模型。

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
配色主题定义和配色库检索层。

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
    
    /// 判断是否是暗色系主题
    public var isDark: Bool { get }
}

public enum GhosttyThemeCatalog {
    /// 内置的精选主题集
    public static let allThemes: [GhosttyThemeDefinition]
    
    /// 查找指定名称的主题
    public static func theme(named name: String) -> GhosttyThemeDefinition?
    
    /// 模糊搜索主题
    public static func search(_ query: String) -> [GhosttyThemeDefinition]
}
```

---

## 快速使用示例

### 初始化运行时与渲染 View

```swift
import SwiftUI
import libghostty_swift

// 1. 初始化终端配置
var config = GhosttySurfaceConfiguration()
config.fontSize = 14
config.workingDirectory = NSHomeDirectory()
config.command = "/usr/bin/ssh steve@192.168.1.1"

// 2. 创建 Surface 视图
let terminalView = GhosttySurfaceView(config: config)

// 3. 热切换主题配色
if let dracula = GhosttyThemeCatalog.theme(named: "Dracula") {
    terminalView.applyTheme(dracula)
}
```
