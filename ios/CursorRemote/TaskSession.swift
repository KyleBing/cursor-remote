import Foundation
import Observation

/// 单个文件的改动统计（详情页列表用）
struct FileChange: Identifiable, Hashable {
    var path: String
    var add: Int
    var del: Int

    var id: String { path }

    /// 只显示文件名
    var name: String { (path as NSString).lastPathComponent }
}

/// 渲染用的一段内容块
struct Block: Identifiable, Hashable {
    enum Kind: Hashable {
        case user      // 用户指令
        case assistant // 助手正文（用户该看的结论）
        case thinking  // 中间思考（界面只展示一两行摘要）
        case files     // 改动文件列表
        case info      // 系统提示
        case error     // 错误 / stderr
    }

    var id: Int
    var kind: Kind
    var text: String
    var files: [FileChange] = []
}

/// 单个任务的实时会话：负责订阅 SSE、累积事件、驱动界面。
@Observable
final class TaskSession {
    var info: TaskInfo
    var blocks: [Block] = []
    var connectionText = "未连接"
    var busy = false
    var lastError: String?

    /// 已收到的事件（去重后）
    private(set) var events: [AgentEvent] = []

    private var lastSeq = 0
    private var lastEventType = ""
    /// 已计入文件列表的 tool call，避免 started/completed 各加一遍
    private var countedCallIDs: Set<String> = []
    private var loop: Task<Void, Never>?

    init(info: TaskInfo) {
        self.info = info
    }

    deinit {
        loop?.cancel()
    }

    /// 启动：先补全量，再持续订阅
    func start(client: APIClient) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            await self.loadDetail(client: client)
            await self.pump(client: client)
        }
    }

    /// 停止本地订阅
    func stopStream() {
        loop?.cancel()
        loop = nil
    }

    /// 手动刷新一次全量数据
    func reload(client: APIClient) async {
        await loadDetail(client: client)
    }

    /// 重新建立订阅（从后台回到前台、或手动刷新时用）
    func restart(client: APIClient) {
        stopStream()
        start(client: client)
    }

    // MARK: - 数据加载

    /// 拉取全量详情，用于首次进入和断线对齐
    private func loadDetail(client: APIClient) async {
        do {
            let detail = try await client.task(id: info.id)
            info = detail.info
            events = detail.events
            lastSeq = detail.events.map(\.seq).max() ?? 0
            rebuildBlocks()
            connectionText = info.isRunning ? "已同步，订阅中…" : "已结束"
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 订阅循环：断线自动重连，续传点位由 lastSeq 决定
    private func pump(client: APIClient) async {
        var attempt = 0
        while !Task.isCancelled {
            connectionText = attempt == 0 ? "订阅中…" : "重连中（第 \(attempt) 次）…"
            var ended = false
            do {
                for try await frame in client.stream(id: info.id, after: lastSeq) {
                    switch frame {
                    case .task(let t):
                        info = t
                    case .event(let e):
                        ingest(e)
                    case .done(let status):
                        info.status = status
                        ended = true
                    }
                    attempt = 0
                }
            } catch {
                if Task.isCancelled { return }
                connectionText = "连接断开：\(error.localizedDescription)"
            }

            if ended || !info.isRunning {
                connectionText = "已结束"
                // 收尾再拉一次，确保 result / 耗时字段是最新的
                await loadDetail(client: client)
                return
            }
            attempt += 1
            if attempt > 20 {
                connectionText = "重连失败，请下拉刷新"
                return
            }
            // 退避重连，最长 4 秒一次
            let delay = UInt64(min(attempt, 5)) * 800_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    // MARK: - 事件累积

    /// 增量并入一条事件
    private func ingest(_ e: AgentEvent) {
        guard e.seq > lastSeq else { return }
        lastSeq = e.seq
        events.append(e)

        switch e.type {
        case "status":
            if let s = e.text { info.status = s }
        case "user":
            if let text = e.text, !text.isEmpty, text != info.prompt {
                blocks.append(Block(id: e.seq, kind: .user, text: text))
            }
        case "assistant":
            appendAssistant(seq: e.seq, text: e.text ?? "")
        case "thinking":
            appendThinking(seq: e.seq, text: e.text ?? "")
        case "tool_call":
            // 不展示具体操作步骤；只把改文件汇总进列表
            if e.sub == "completed" || e.sub == "started" {
                applyFileChange(from: e)
            }
        case "stderr", "error":
            if let text = e.text, !text.isEmpty {
                blocks.append(Block(id: e.seq, kind: .error, text: text))
            }
        case "info":
            // 旧数据里思考被标成 info，直接丢掉；只保留会话就绪 / 审批提示
            if e.sub == "thinking" { break }
            if let text = e.text, !text.isEmpty, e.sub == "init" || e.sub == "approval" {
                blocks.append(Block(id: e.seq, kind: .info, text: text))
            }
        default:
            break
        }
        lastEventType = e.type
    }

    /// 从头重建块列表（首次加载 / 重连后）
    private func rebuildBlocks() {
        var out: [Block] = []
        var fileMap: [String: FileChange] = [:]
        var filesBlockIndex: Int?
        var seenCalls: Set<String> = []
        var prevType = ""

        for e in events {
            switch e.type {
            case "user":
                if let text = e.text, !text.isEmpty, text != info.prompt {
                    out.append(Block(id: e.seq, kind: .user, text: text))
                }
            case "assistant":
                mergeAssistant(into: &out, seq: e.seq, text: e.text ?? "", prevType: prevType)
            case "thinking":
                mergeThinking(into: &out, seq: e.seq, text: e.text ?? "")
            case "tool_call":
                if e.sub == "completed" || e.sub == "started" {
                    let callKey = e.callID ?? "seq-\(e.seq)"
                    // 有 completed 时跳过对应 started，避免加减两遍
                    if e.sub == "started",
                       events.contains(where: { $0.callID == e.callID && $0.sub == "completed" }) {
                        break
                    }
                    if seenCalls.contains(callKey) { break }
                    if let change = FileChangeParser.parse(tool: e.tool, detail: e.detail) {
                        seenCalls.insert(callKey)
                        mergeFile(change, into: &fileMap)
                        upsertFilesBlock(seq: e.seq, fileMap: fileMap, into: &out, index: &filesBlockIndex)
                    }
                }
            case "stderr", "error":
                if let text = e.text, !text.isEmpty {
                    out.append(Block(id: e.seq, kind: .error, text: text))
                }
            case "info":
                if e.sub == "thinking" { break }
                if let text = e.text, !text.isEmpty, e.sub == "init" || e.sub == "approval" {
                    out.append(Block(id: e.seq, kind: .info, text: text))
                }
            default:
                break
            }
            prevType = e.type
        }
        blocks = out
        countedCallIDs = seenCalls
        lastEventType = events.last?.type ?? ""
    }

    // MARK: - 块合并

    /// 流式助手正文：合并增量，并用完整帧覆盖重复拼接
    private func appendAssistant(seq: Int, text: String) {
        guard !text.isEmpty else { return }
        if lastEventType == "assistant", var last = blocks.last, last.kind == .assistant {
            last.text = Self.mergeAssistantText(last.text, text)
            blocks[blocks.count - 1] = last
        } else {
            blocks.append(Block(id: seq, kind: .assistant, text: text))
        }
    }

    private func mergeAssistant(into out: inout [Block], seq: Int, text: String, prevType: String) {
        guard !text.isEmpty else { return }
        if prevType == "assistant", var last = out.last, last.kind == .assistant {
            last.text = Self.mergeAssistantText(last.text, text)
            out[out.count - 1] = last
        } else {
            out.append(Block(id: seq, kind: .assistant, text: text))
        }
    }

    /// 增量 token 追加；若新帧是已有正文的完整版则替换，避免「流式 + 整段」翻倍
    static func mergeAssistantText(_ current: String, _ incoming: String) -> String {
        if incoming == current { return current }
        if incoming.hasPrefix(current) { return incoming }
        if current.hasPrefix(incoming) { return current }
        return current + incoming
    }

    private func appendThinking(seq: Int, text: String) {
        guard !text.isEmpty else { return }
        // 全程只保留一块思考，避免步骤间反复插入占篇幅
        if let idx = blocks.firstIndex(where: { $0.kind == .thinking }) {
            blocks[idx].text += text
        } else {
            blocks.append(Block(id: seq, kind: .thinking, text: text))
        }
    }

    private func mergeThinking(into out: inout [Block], seq: Int, text: String) {
        guard !text.isEmpty else { return }
        if let idx = out.firstIndex(where: { $0.kind == .thinking }) {
            out[idx].text += text
        } else {
            out.append(Block(id: seq, kind: .thinking, text: text))
        }
    }

    /// 把一次改文件事件并入列表块
    private func applyFileChange(from e: AgentEvent) {
        let callKey = e.callID ?? "seq-\(e.seq)"
        if countedCallIDs.contains(callKey) { return }
        // 先到的 started 先展示；随后 completed 若已计入同 call 则跳过
        guard let change = FileChangeParser.parse(tool: e.tool, detail: e.detail) else { return }
        countedCallIDs.insert(callKey)

        var fileMap: [String: FileChange] = [:]
        if let existing = blocks.first(where: { $0.kind == .files }) {
            for f in existing.files { fileMap[f.path] = f }
        }
        mergeFile(change, into: &fileMap)

        if let idx = blocks.firstIndex(where: { $0.kind == .files }) {
            blocks[idx].files = Self.sortedFiles(fileMap)
            blocks[idx].text = "\(fileMap.count) 个文件"
        } else {
            blocks.append(Block(id: e.seq, kind: .files, text: "\(fileMap.count) 个文件", files: Self.sortedFiles(fileMap)))
        }
    }

    private func mergeFile(_ change: FileChange, into map: inout [String: FileChange]) {
        if var cur = map[change.path] {
            cur.add += change.add
            cur.del += change.del
            map[change.path] = cur
        } else {
            map[change.path] = change
        }
    }

    private func upsertFilesBlock(seq: Int, fileMap: [String: FileChange], into out: inout [Block], index: inout Int?) {
        let files = Self.sortedFiles(fileMap)
        if let i = index {
            out[i].files = files
            out[i].text = "\(files.count) 个文件"
        } else {
            index = out.count
            out.append(Block(id: seq, kind: .files, text: "\(files.count) 个文件", files: files))
        }
    }

    private static func sortedFiles(_ map: [String: FileChange]) -> [FileChange] {
        map.values.sorted { $0.path < $1.path }
    }

    // MARK: - 操作

    /// 停止远端任务
    func stop(client: APIClient) async {
        busy = true
        defer { busy = false }
        do {
            try await client.stop(id: info.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 续接一轮指令
    func followUp(client: APIClient, prompt: String) async {
        busy = true
        defer { busy = false }
        do {
            try await client.followUp(id: info.id, prompt: prompt)
            info.status = "running"
            // 重新开始订阅，继续追加到同一事件流
            loop?.cancel()
            loop = nil
            start(client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

// MARK: - 解析工具 detail 里的文件改动

enum FileChangeParser {
    /// 从 tool + detail 解析出路径与增减行；兼容旧版带 streamContent 的 detail
    static func parse(tool: String?, detail: String?) -> FileChange? {
        guard let tool, isFileTool(tool) else { return nil }
        guard let detail, !detail.isEmpty else { return nil }

        if let data = detail.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = obj["path"] as? String, !path.isEmpty {
            // 新格式：服务端已算好 add/del
            if obj["add"] != nil || obj["del"] != nil {
                return FileChange(path: path, add: intValue(obj["add"]), del: intValue(obj["del"]))
            }
            // 旧格式：detail 里带着 streamContent 正文
            if let content = obj["streamContent"] as? String {
                return FileChange(path: path, add: lineCount(content), del: 0)
            }
            if let content = obj["contents"] as? String {
                return FileChange(path: path, add: lineCount(content), del: tool == "delete" ? lineCount(content) : 0)
            }
            return FileChange(path: path, add: 0, del: tool == "delete" ? 1 : 0)
        }

        // detail 被截断时 JSON 可能坏掉，用正则捞 path，并用 \\n 粗估行数
        guard let path = match(detail, pattern: #""path"\s*:\s*"((?:\\.|[^"\\])*)""#) else { return nil }
        let unescaped = path
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\\", with: "\\")
        let add: Int
        if let content = match(detail, pattern: #""streamContent"\s*:\s*"(.*)$"#) {
            add = content.components(separatedBy: "\\n").count
        } else {
            add = 0
        }
        return FileChange(path: unescaped, add: add, del: tool == "delete" ? 1 : 0)
    }

    private static func isFileTool(_ tool: String) -> Bool {
        switch tool {
        case "edit", "write", "delete": return true
        default: return false
        }
    }

    private static func intValue(_ v: Any?) -> Int {
        switch v {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        default: return 0
        }
    }

    private static func lineCount(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        let n = s.filter { $0 == "\n" }.count
        return s.hasSuffix("\n") ? n : n + 1
    }

    private static func match(_ text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
