import AppKit

// 顶层代码是 nonisolated 的，而 AppDelegate 及其持有的两个 store 都是 @MainActor。
// 这里本来就跑在主线程上，显式声明一下即可。
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
