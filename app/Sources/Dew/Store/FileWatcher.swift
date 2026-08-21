import Foundation

/// FSEvents 递归目录监听。
///
/// 为什么需要它：轮询节拍决定了「文件变了多久后你才看见」。
/// 单靠轮询要么慢、要么空转。FSEvents 让文件一变就立刻回调，
/// 轮询则退居二线，只负责那些**不由文件事件驱动**的时间态变化
/// （比如「停了超过 N 秒算等你介入」）。
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dew.fsevents")
    private let onChange: () -> Void

    init(paths: [URL], onChange: @escaping () -> Void) {
        self.onChange = onChange
        start(paths: paths.filter { FileManager.default.fileExists(atPath: $0.path) })
    }

    deinit { stop() }

    private func start(paths: [URL]) {
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        // latency 0.15s：把一次工具调用产生的连串写入合并成一次回调，
        // 既跟手又不至于每写一行就重扫一遍。
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
