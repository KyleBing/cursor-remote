import Foundation
import Observation

/// 渲染用的一段内容块
struct Block: Identifiable, Hashable {
    enum Kind: Hashable {
        case user      // 用户指令
        case assistant // 助手正文
        case tool      // 工具调用
        case info      // 系统提示
        case error     // 错误 / stderr
    }

    var id: Int
    var kind: Kind
    var text: String
    var tool: String?
    var detail: String?
    var running: Bool = false
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
            return
        case "assistant":
            guard let text = e.text, !text.isEmpty else { return }
            // 连续的增量片段合并到同一个块
            if lastEventType == "assistant", var last = blocks.last, last.kind == .assistant {
                last.text += text
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(Block(id: e.seq, kind: .assistant, text: text))
            }
        case "tool_call":
            if e.sub == "started" {
                blocks.append(Block(id: e.seq, kind: .tool, text: e.callID ?? "", tool: e.tool, detail: e.detail, running: true))
            } else if let idx = blocks.lastIndex(where: { $0.kind == .tool && $0.text == (e.callID ?? "") && $0.running }) {
                blocks[idx].running = false
                if let d = e.detail, !d.isEmpty { blocks[idx].detail = d }
            }
        case "stderr", "error":
            if let text = e.text, !text.isEmpty {
                blocks.append(Block(id: e.seq, kind: .error, text: text))
            }
        case "info":
            if let text = e.text, !text.isEmpty {
                blocks.append(Block(id: e.seq, kind: .info, text: text))
            }
        default:
            if let text = e.text, !text.isEmpty {
                blocks.append(Block(id: e.seq, kind: .info, text: text))
            }
        }
        lastEventType = e.type
    }

    /// 从头重建块列表（首次加载 / 重连后）
    private func rebuildBlocks() {
        var out: [Block] = []
        var prevType = ""
        for e in events {
            switch e.type {
            case "user":
                // 服务端会回显用户输入，首条与任务 prompt 重复则不显示
                if let text = e.text, !text.isEmpty, text != info.prompt {
                    out.append(Block(id: e.seq, kind: .user, text: text))
                }
            case "assistant":
                guard let text = e.text, !text.isEmpty else { continue }
                if prevType == "assistant", var last = out.last, last.kind == .assistant {
                    last.text += text
                    out[out.count - 1] = last
                } else {
                    out.append(Block(id: e.seq, kind: .assistant, text: text))
                }
            case "tool_call":
                if e.sub == "started" {
                    out.append(Block(id: e.seq, kind: .tool, text: e.callID ?? "", tool: e.tool, detail: e.detail, running: true))
                } else if let idx = out.lastIndex(where: { $0.kind == .tool && $0.text == (e.callID ?? "") && $0.running }) {
                    out[idx].running = false
                    if let d = e.detail, !d.isEmpty { out[idx].detail = d }
                }
            case "stderr", "error":
                if let text = e.text, !text.isEmpty {
                    out.append(Block(id: e.seq, kind: .error, text: text))
                }
            case "info":
                if let text = e.text, !text.isEmpty {
                    out.append(Block(id: e.seq, kind: .info, text: text))
                }
            default:
                break
            }
            prevType = e.type
        }
        blocks = out
        lastEventType = events.last?.type ?? ""
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
