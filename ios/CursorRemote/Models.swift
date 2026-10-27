import Foundation

// MARK: - 服务端返回的数据模型（与 server/*.go 的 JSON 对齐）

/// 白名单项目
struct ProjectInfo: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let sessions: Int
    let lastActive: Int64

    var id: String { path }

    /// 最近活跃时间的可读描述
    var lastActiveText: String {
        guard lastActive > 0 else { return "无历史会话" }
        let date = Date(timeIntervalSince1970: Double(lastActive) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 骨架占位（加载中列表用，配合 .redacted 显示灰条）
    static let placeholder = ProjectInfo(
        name: "加载中的项目",
        path: "/Users/you/Developer/project",
        sessions: 0,
        lastActive: 0
    )
}

/// 任务元信息
struct TaskInfo: Codable, Identifiable, Hashable {
    var id: String
    var project: String
    var projectPath: String
    var prompt: String
    var mode: String
    var model: String?
    var approval: String
    var sessionID: String?
    var status: String
    var createdAt: Int64
    var startedAt: Int64?
    var endedAt: Int64?
    var exitCode: Int?
    var result: String?
    var error: String?

    /// 是否仍在跑
    var isRunning: Bool { status == "running" || status == "queued" }

    /// 创建时间
    var createdDate: Date { Date(timeIntervalSince1970: Double(createdAt) / 1000) }

    /// 耗时描述
    var durationText: String {
        guard let ended = endedAt, startedAt != nil else { return "" }
        let start = Double(startedAt ?? createdAt) / 1000
        let seconds = max(0, Double(ended) / 1000 - start)
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%.0f分%.0f秒", seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    /// 骨架占位（加载中列表用，配合 .redacted 显示灰条）
    static let placeholder = TaskInfo(
        id: "placeholder", project: "加载中", projectPath: "/Users/you/Developer/project",
        prompt: "正在拉取任务列表，请稍候", mode: "agent", model: nil, approval: "auto-review",
        sessionID: nil, status: "queued", createdAt: 0, startedAt: nil, endedAt: nil,
        exitCode: nil, result: nil, error: nil
    )
}

/// 一条对话事件
struct AgentEvent: Codable, Identifiable, Hashable {
    let seq: Int
    let at: Int64
    let type: String
    var sub: String?
    var text: String?
    var tool: String?
    var callID: String?
    var detail: String?

    var id: Int { seq }
}

/// 任务详情：元信息 + 完整事件流
struct TaskDetail: Decodable {
    let info: TaskInfo
    let events: [AgentEvent]

    init(from decoder: Decoder) throws {
        // 服务端把 TaskInfo 内嵌在同一层 JSON 里，这里复用同一个 decoder
        info = try TaskInfo(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decodeIfPresent([AgentEvent].self, forKey: .events) ?? []
    }

    private enum CodingKeys: String, CodingKey { case events }
}

/// 服务健康状态
struct Health: Codable {
    let ok: Bool
    let agentPath: String?
    let version: String?
    let loggedIn: Bool?
    let detail: String?
    let projects: Int?

    /// 骨架占位（加载中状态行用，配合 .redacted 显示灰条）
    static let placeholder = Health(
        ok: true, agentPath: nil, version: "0.0.0", loggedIn: true, detail: nil, projects: 0
    )
}

/// 接口错误
struct APIError: LocalizedError, Decodable {
    let error: String
    var errorDescription: String? { error }
}

/// 任务状态的可读描述与配色
enum TaskStatusStyle {
    static func label(_ status: String) -> String {
        switch status {
        case "queued": return "排队中"
        case "running": return "执行中"
        case "done": return "已完成"
        case "failed": return "失败"
        case "stopped": return "已停止"
        default: return status
        }
    }

    static func tint(_ status: String) -> String {
        switch status {
        case "running": return "blue"
        case "done": return "green"
        case "failed": return "red"
        case "stopped": return "orange"
        default: return "gray"
        }
    }
}
