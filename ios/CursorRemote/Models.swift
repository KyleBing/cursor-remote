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

/// 白名单受管程序（带运行态）
struct ProgramStatus: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    var running: Bool
    var pid: Int?
    var memoryBytes: Int64?
    var detail: String?

    /// 种类的可读描述
    var kindLabel: String {
        switch kind {
        case "launchagent": return "服务"
        default: return "应用"
        }
    }

    static let placeholder = ProgramStatus(
        id: "placeholder", name: "加载中", kind: "app",
        running: false, pid: nil, memoryBytes: nil, detail: nil
    )
}

/// 本机正在运行的前台应用
struct RunningApp: Codable, Identifiable, Hashable {
    let name: String
    let bundleId: String?
    let pid: Int
    let memoryBytes: Int64?
    let path: String?

    var id: String { "\(pid)-\(name)" }

    static let placeholder = RunningApp(
        name: "加载中的应用", bundleId: nil, pid: 0, memoryBytes: 120_000_000, path: "/Applications/App.app"
    )
}

// MARK: - 本机系统信息

struct SystemInfo: Codable {
    let at: Int64
    let hardware: HardwareInfo
    let memory: MemoryInfo
    let disks: [DiskInfo]
    let battery: BatteryInfo
    var display: DisplayInfo
    var audio: AudioInfo
    let network: NetworkInfo
    let bluetooth: BluetoothInfo
    let loadAvg: [Double]?
    let uptimeSec: Int64?

    /// 开机时长可读
    var uptimeText: String {
        guard let sec = uptimeSec, sec > 0 else { return "—" }
        let d = sec / 86400
        let h = (sec % 86400) / 3600
        let m = (sec % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分钟"
    }

    var loadText: String {
        guard let load = loadAvg, !load.isEmpty else { return "—" }
        return load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }
}

struct HardwareInfo: Codable {
    let modelName: String
    let modelIdentifier: String
    let chip: String
    let cores: String?
    let memoryGB: Int
    let serialNumber: String?
}

struct MemoryInfo: Codable {
    let totalBytes: Int64
    let usedBytes: Int64
    let freeBytes: Int64
    let wiredBytes: Int64?
    let compressedBytes: Int64?
    let appBytes: Int64?
    let swapTotalBytes: Int64?
    let swapUsedBytes: Int64?
    let pressure: String?
    let usedPercent: Double
}

struct DiskInfo: Codable, Identifiable {
    let mount: String
    let device: String?
    let totalBytes: Int64
    let usedBytes: Int64
    let freeBytes: Int64
    let usedPercent: Double
    var id: String { mount + (device ?? "") }
}

struct BatteryInfo: Codable {
    let percent: Int
    let charging: Bool
    let acPower: Bool
    let present: Bool
    let timeLeftMin: Int?
    let detail: String?

    var statusText: String {
        if !present { return "无电池" }
        if charging { return "充电中" }
        if acPower { return "接电源" }
        return "使用电池"
    }
}

struct DisplayInfo: Codable {
    let brightness: Double
    let brightnessPct: Int
    let nits: Double?
    let autoBrightness: Bool
}

struct AudioInfo: Codable {
    let outputVolume: Int
    let inputVolume: Int
    let alertVolume: Int
    let muted: Bool
}

struct NetworkInfo: Codable {
    let primaryInterface: String
    let ipv4: String?
    let ipv6: String?
    let gateway: String?
    let dns: [String]?
    let wifi: WiFiInfo?
}

struct WiFiInfo: Codable {
    let connected: Bool
    let ssid: String?
    let channel: String?
    let phyMode: String?
    let signalDBm: String?
    let noiseDBm: String?
    let transmitMbps: String?
    let security: String?
}

struct BluetoothInfo: Codable {
    let on: Bool
    let address: String?
    let connected: [BluetoothDevice]
    let paired: [BluetoothDevice]
}

struct BluetoothDevice: Codable, Identifiable, Hashable {
    let name: String
    let address: String?
    let type: String?
    let connected: Bool
    let battery: String?
    let rssi: String?

    var id: String { (address ?? name) + (connected ? "-c" : "-p") }
}

/// 字节数格式化（KB / MB / GB）
enum ByteFormat {
    static func string(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}

/// Applications 目录里可打开的应用
struct AvailableApp: Codable, Identifiable, Hashable {
    let name: String
    let path: String

    var id: String { path }
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
