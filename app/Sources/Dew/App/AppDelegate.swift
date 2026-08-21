import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var statusItem: NSStatusItem?
    private let agents: AgentStore
    private let todos: TodoStore

    override init() {
        // DEW_DEMO=1：演示模式。会话 / 定时任务 / 额度 / 待办全是假数据，
        // 不读任何 Agent 目录、不碰 todos.json。用于截图、录屏。
        let demo = ProcessInfo.processInfo.environment["DEW_DEMO"] != nil
        agents = demo ? AgentStore(adapters: DemoAdapter.all) : AgentStore()
        todos = TodoStore(demo: demo)
        super.init()
    }

    private let originKey = "panel.origin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 不进 Dock，只做常驻组件

        let size = Metrics.collapsedSize
        let origin = savedOrigin(for: size)
        let rect = NSRect(origin: origin, size: size)

        let p = FloatingPanel(contentRect: rect)
        let root = RootView(chrome: PanelChrome.shared)
            .environmentObject(agents)
            .environmentObject(todos)
            .environmentObject(AppSettings.shared)

        let host = InteractiveHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host

        PanelChrome.shared.panel = p
        p.orderFrontRegardless()
        panel = p

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !PanelChrome.shared.isResizingProgrammatically else { return }
                self?.saveOrigin()
            }
        }

        setupStatusItem()

        // 开发期开关：DEW_DEBUG=1 打印窗口诊断，DEW_EXPANDED=1 启动即展开
        let env = ProcessInfo.processInfo.environment
        if env["DEW_DEBUG"] != nil {
            NSLog("[gb] screen.visibleFrame=%@", NSStringFromRect(NSScreen.main?.visibleFrame ?? .zero))
            NSLog("[gb] panel.frame=%@ visible=%d level=%ld",
                  NSStringFromRect(p.frame), p.isVisible ? 1 : 0, p.level.rawValue)
        }
        if let mode = env["DEW_EXPANDED"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                PanelChrome.shared.expand()
                if mode == "todo"  { PanelChrome.shared.requestTab(.todo) }
                if mode == "usage" { PanelChrome.shared.requestTab(.usage) }
                if env["DEW_SETTINGS"] != nil { PanelChrome.shared.showSettings = true }
                if env["DEW_DEBUG"] != nil {
                    NSLog("[gb] sessions=%ld tasks=%ld", self.agents.sessions.count, self.agents.tasks.count)
                }
            }
        }
    }

    // MARK: - 位置记忆

    private func savedOrigin(for size: CGSize) -> CGPoint {
        if let d = UserDefaults.standard.dictionary(forKey: originKey),
           let x = d["x"] as? Double, let y = d["y"] as? Double {
            let pt = CGPoint(x: x, y: y)
            // 换了显示器配置后可能落在屏幕外，落在外面就回到默认位置
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: pt, size: size)) }) {
                return pt
            }
        }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 24)
    }

    private func saveOrigin() {
        guard let f = panel?.frame else { return }
        // 存左上角，这样展开/折叠切换尺寸后位置感受一致
        UserDefaults.standard.set(["x": f.minX, "y": f.maxY - Metrics.collapsedSize.height],
                                  forKey: originKey)
    }

    // MARK: - 菜单栏入口
    //
    // 没有 Dock 图标，也就没有退出的地方，所以必须留一个菜单栏项。

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "drop",
                                     accessibilityDescription: "Dew")
        let menu = NSMenu()
        menu.addItem(withTitle: L(.menuToggle), action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: L(.menuResetPosition), action: #selector(resetPosition), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L(.menuQuit), action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        PanelChrome.shared.toggle()
        panel?.orderFrontRegardless()
    }

    @objc private func resetPosition() {
        guard let panel else { return }
        let size = PanelChrome.shared.isExpanded ? Metrics.expandedSize : Metrics.collapsedSize
        let vf = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 24))
        saveOrigin()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
