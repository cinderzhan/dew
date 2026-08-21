import SwiftUI

/// 皮肤契约（PRD 9.5）。
///
/// 皮肤**只能**改这里的颜色与材质。布局、间距、圆角、磨砂参数、字体、
/// 四态语义、以及「折叠态只显示一个信号」这条铁律，全部由 Metrics 固定，
/// 皮肤碰不到。这道边界是产品统一气质的保障，不要为了某个皮肤好看而破例。
struct Skin: Sendable {
    let id: String
    let name: String

    // 玻璃底 —— 叠在磨砂之上的一层薄色，控制冷暖
    let tint: Color
    // 文字
    let text: Color
    let dim: Color
    let faint: Color
    // 线与选中底
    let line: Color
    let selection: Color
    // 语义色。三个状态三个点色：等你介入 = 红，已完成 = 绿，进行中 = 橙。
    // 红和橙在 6pt 圆点上容易混，所以信号色取偏正的红、进行中取偏黄的橙，把两者拉开。
    let signal: Color   // 等你介入。整个界面唯一的强调色。
    let running: Color  // 进行中
    let done: Color     // 已完成
    /// 信号点形状：0 = 圆，>0 = 圆角方
    let dotCornerRadius: CGFloat

    static func plain(_ scheme: ColorScheme) -> Skin {
        scheme == .dark
        ? Skin(id: "plain", name: "素",
               tint:      Color(red: 0.118, green: 0.125, blue: 0.141).opacity(0.66),
               text:      Color(red: 0.945, green: 0.949, blue: 0.957),
               dim:       Color(red: 0.651, green: 0.675, blue: 0.702),
               faint:     Color(red: 0.463, green: 0.486, blue: 0.518),
               line:      Color.white.opacity(0.115),
               selection: Color.white.opacity(0.075),
               signal:    Color(red: 1.000, green: 0.420, blue: 0.400),
               running:   Color(red: 1.000, green: 0.720, blue: 0.300),
               done:      Color(red: 0.373, green: 0.780, blue: 0.604),
               dotCornerRadius: 0)
        : Skin(id: "plain", name: "素",
               tint:      Color(red: 0.988, green: 0.988, blue: 0.992).opacity(0.70),
               text:      Color(red: 0.067, green: 0.071, blue: 0.078),
               dim:       Color(red: 0.357, green: 0.376, blue: 0.400),
               faint:     Color(red: 0.541, green: 0.565, blue: 0.596),
               line:      Color(red: 0.078, green: 0.086, blue: 0.110).opacity(0.10),
               selection: Color(red: 0.078, green: 0.086, blue: 0.110).opacity(0.055),
               signal:    Color(red: 0.870, green: 0.220, blue: 0.200),
               running:   Color(red: 0.930, green: 0.600, blue: 0.120),
               done:      Color(red: 0.180, green: 0.655, blue: 0.420),
               dotCornerRadius: 0)
    }

    func color(for state: SessionState) -> Color {
        switch state {
        case .needsYou: return signal
        case .running:  return running
        case .done:     return done
        case .idle:     return faint
        }
    }
}

/// 皮肤不可改的部分。
enum Metrics {
    static let collapsedSize = CGSize(width: 296, height: 38)
    static let expandedSize  = CGSize(width: 344, height: 460)
    static let corner: CGFloat = 15
    static let hPad: CGFloat = 14
    static let rowVPad: CGFloat = 6
    static let bodyFont = Font.system(size: 12.5)
    static let metaFont = Font.system(size: 11)
    static let groupFont = Font.system(size: 10, weight: .semibold)
    static let sigFont = Font.system(size: 12.5, weight: .semibold)
}

/// 磨砂基底。皮肤在它之上叠 tint，改变的只是颜色，不是材质参数。
struct GlassBackground: NSViewRepresentable {
    /// 磨砂层的不透明度，连续可调。
    ///
    /// 之前误以为 alphaValue 会造成残影，其实残影的真凶是透明窗口的阴影快照
    ///（见 InteractiveHostingView.layout 里的 invalidateShadow）。那个修好之后，
    /// 这里连续调 alpha 是安全的，而且比换材质档位顺滑得多。
    var alpha: Double = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.alphaValue = alpha
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if abs(nsView.alphaValue - alpha) > 0.001 { nsView.alphaValue = alpha }
    }
}

/// 关掉滚动视图的 copy-on-scroll。
///
/// 磨砂层 alpha < 1 之后整个视图不再是不透明的，而 NSScrollView 默认会
/// 「复制已绘制内容再平移」来省重绘。背景不实心时旧内容擦不干净，
/// 表现就是滚动后文字层层叠叠糊在一起。放一个零尺寸探针进去关掉它。
struct ScrollTrailFix: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let sv = enclosingScrollView else { return }
            sv.contentView.copiesOnScroll = false
            sv.drawsBackground = false
            sv.backgroundColor = .clear
        }
    }

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 可拖动窗口的区域。
///
/// 展开态关掉了 isMovableByWindowBackground（否则复选框、滑块的事件会被抢走），
/// 所以要留一块明确的拖动区。performDrag 走的是系统那套，手感和原生标题栏一致。
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            // 抬头区双击 = 收起。比点右上角那个小箭头好命中得多。
            if event.clickCount == 2 {
                Task { @MainActor in PanelChrome.shared.collapse() }
                return
            }
            window?.performDrag(with: event)
        }
        // 面板常年不是 key window，不重写这个的话第一次按下会被吞
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
