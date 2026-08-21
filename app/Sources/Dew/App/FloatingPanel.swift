import AppKit
import SwiftUI
import Combine

/// 折叠 / 展开的状态与窗口尺寸联动。
@MainActor
final class PanelChrome: ObservableObject {
    static let shared = PanelChrome()

    @Published private(set) var isExpanded = false
    weak var panel: NSPanel?

    /// 程序化改尺寸期间置位。setFrame 会触发 didMove，
    /// 若不区分「用户拖动」和「程序改尺寸」，位置会跨启动一点点漂走。
    private(set) var isResizingProgrammatically = false

    /// 外部请求切换 tab（目前只有开发期调试开关用）
    @Published var pendingTab: PanelTab?
    func requestTab(_ t: PanelTab) { pendingTab = t }

    /// 设置面板的开合。放在这里而不是视图局部状态，
    /// 是为了让收起面板时它能一并归位。
    @Published var showSettings = false

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        resize(to: Metrics.expandedSize)
        // 展开态里有复选框、滑块、输入框。整片背景可拖会把这些控件的
        // mouseDown / drag 抢走——滑块尤其明显，拖它变成拖窗口。
        panel?.isMovableByWindowBackground = false
        // 展开是「我要动手了」的信号，此时才接管键盘（待办输入框需要）。
        // 折叠态保持不抢焦点。
        panel?.makeKeyAndOrderFront(nil)
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        showSettings = false
        panel?.isMovableByWindowBackground = true
        resize(to: Metrics.collapsedSize)
    }

    func toggle() { isExpanded ? collapse() : expand() }

    /// 左上角锚定：展开时向下长，不要把整条往上顶。
    /// 展开态比折叠态更宽也更高，靠边摆放时会溢出屏幕，所以要夹回可见区。
    private func resize(to size: CGSize) {
        guard let panel else { return }
        let old = panel.frame
        var newFrame = NSRect(x: old.minX,
                              y: old.maxY - size.height,
                              width: size.width,
                              height: size.height)

        if let vf = (panel.screen ?? NSScreen.main)?.visibleFrame {
            newFrame.origin.x = min(newFrame.minX, vf.maxX - size.width)
            newFrame.origin.x = max(newFrame.minX, vf.minX)
            newFrame.origin.y = max(newFrame.minY, vf.minY)
            newFrame.origin.y = min(newFrame.minY, vf.maxY - size.height)
        }

        isResizingProgrammatically = true
        panel.setFrame(newFrame, display: true, animate: false)
        DispatchQueue.main.async { [weak self] in
            self?.isResizingProgrammatically = false
        }
    }
}

/// 无边框、可拖动、悬浮在其它窗口之上的面板。
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   // 注意：.fullSizeContentView 必须配合 .titled，跟 .borderless 混用会得到一个无效窗口。
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        // 跟着切换空间、并且允许出现在全屏应用之上
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true

        hidesOnDeactivate = false
        animationBehavior = .none
        // 默认 true 会让面板「非必要不接管键盘」，输入框与滑块因此收不到事件
        becomesKeyOnlyIfNeeded = false
    }

    // 待办输入框需要键盘焦点，所以必须能成为 key window
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc 收起
    override func cancelOperation(_ sender: Any?) {
        PanelChrome.shared.collapse()
    }
}

/// 承载 SwiftUI 的宿主视图。
///
/// 必须重写 acceptsFirstMouse：NSHostingView 默认返回 false，意味着窗口不是
/// key 时的第一次点击只用于激活窗口、事件本身被吞掉。本面板刻意常年不激活
/// （nonactivatingPanel + accessory 应用），于是**每一次点击都算「第一次」**，
/// 结果就是 hover 有反应、点击永远没反应。
final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 透明窗口的经典坑：阴影由内容快照计算，内容更新后快照不自动失效，
    // 旧内容会以浅色「印」的形式残留在窗口上（结构怎么改都消不掉的那种残影）。
    // 每次布局后手动失效。
    override func layout() {
        super.layout()
        window?.invalidateShadow()
    }
}

enum NSWorkspaceReveal {
    static func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
