import AppKit
import Foundation

enum NSWorkspaceReveal {
    static func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 同一条深链短时间内只放行一次。
    /// claude://resume 的语义是「导入」而非「聚焦」，桌面端不去重——连点两下就是两条重复会话。
    nonisolated(unsafe) private static var lastOpened: [String: Date] = [:]
    private static let debounce: TimeInterval = 3

    /// 先试深链；没有、或者系统里没有任何 app 认领这个 scheme，就退回 Finder 定位。
    static func open(_ deepLink: URL?, fallbackPath: String) {
        if let url = deepLink,
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            let key = url.absoluteString
            if let t = lastOpened[key], Date().timeIntervalSince(t) < debounce { return }
            lastOpened[key] = Date()
            NSWorkspace.shared.open(url)
        } else {
            reveal(path: fallbackPath)
        }
    }
}
