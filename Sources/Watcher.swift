import Foundation
import CoreServices

/// 监听 ~/.claude/projects 下的写入，把变更的 .jsonl 路径批量报给回调。
///
/// FSEvents 在活跃会话里会高频触发（Claude 每写一行就是一次事件），
/// 所以这里做 1 秒的合并窗口：窗口内的路径去重后一次性上报。
final class ProjectsWatcher {

    private let root: String
    private let onBatch: ([String]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "claude-session-search.watcher")

    /// 合并窗口内累积的路径。只在 queue 上访问。
    private var pending = Set<String>()
    private var flushScheduled = false

    /// 合并窗口长度。活跃会话每秒可能产生几十次写入，
    /// 攒一下再索引比每次都开库便宜得多。
    private let coalesceWindow: DispatchTimeInterval = .seconds(1)

    init(root: String, onBatch: @escaping ([String]) -> Void) {
        self.root = root
        self.onBatch = onBatch
    }

    deinit { stop() }

    /// - Returns: 是否成功启动监听
    func start() -> Bool {
        guard stream == nil else { return true }

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectsWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

            let flagArray = UnsafeBufferPointer(start: flags, count: count)
            var changed: [String] = []
            for (i, path) in paths.enumerated() where i < flagArray.count {
                let flag = flagArray[i]
                // 只关心文件层面的改动；目录级事件（如新建项目目录）
                // 会由随后的文件事件覆盖到。
                let isFileEvent = flag & UInt32(kFSEventStreamEventFlagItemIsFile) != 0
                guard isFileEvent, path.hasSuffix(".jsonl") else { continue }
                changed.append(path)
            }
            guard !changed.isEmpty else { return }
            watcher.enqueue(changed)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,                       // FSEvents 自己的延迟窗口
            flags
        ) else { return false }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        return FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - 合并窗口

    private func enqueue(_ paths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.formUnion(paths)
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + self.coalesceWindow) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                let batch = Array(self.pending)
                self.pending.removeAll()
                guard !batch.isEmpty else { return }
                self.onBatch(batch)
            }
        }
    }
}
