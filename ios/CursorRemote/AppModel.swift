import Foundation
import Observation

/// 全局状态：服务器地址、token、项目与任务列表。
/// 全部状态读写都在主线程，避免后台 Task 里改 @Observable 属性导致界面抖动。
@MainActor
@Observable
final class AppModel {
    private static let urlKey = "cursorremote.baseURL"
    private static let configuredKey = "cursorremote.configured"

    // 默认走 VPS 反向隧道：阿里云 nginx 的 /cursor-remote/ 前缀，与 Mac 上的服务同源
    static let defaultBaseURL = "https://kylebing.cn/cursor-remote"

    // 设置页绑定的输入值
    var baseURLText: String
    var tokenText: String

    // 运行态
    var health: Health?
    var projects: [ProjectInfo] = []
    var tasks: [TaskInfo] = []
    /// 白名单受管程序
    var programs: [ProgramStatus] = []
    /// 本机正在运行的前台应用
    var runningApps: [RunningApp] = []
    /// 本机系统信息（硬件 / 电池 / 网络等）
    var systemInfo: SystemInfo?
    var isLoading = false
    var lastError: String?
    /// 是否已完成初始配置（持久化标记；输入框里非空不算）
    private(set) var configured: Bool
    /// 正在进行的全量刷新，用于合并并发调用
    private var inFlightRefresh: Task<Void, Never>?

    init() {
        // 没存过就用默认地址，省得每次手输
        baseURLText = UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultBaseURL
        tokenText = TokenStore.load() ?? ""
        configured = UserDefaults.standard.bool(forKey: Self.configuredKey)
    }

    /// 是否已完成初始配置。
    /// 以「已成功落盘的标记」为准，不能只看输入框非空——否则用户一粘贴 token
    /// 界面就跳走，保存逻辑永远执行不到，重启后 token 又空了。
    var isConfigured: Bool { configured && client != nil }

    /// 当前客户端；地址或 token 不完整时为 nil
    var client: APIClient? {
        guard let url = normalizedURL, !tokenText.isEmpty else { return nil }
        return APIClient(baseURL: url, token: tokenText)
    }

    /// 把输入框里的地址补全成 URL
    private var normalizedURL: URL? {
        var text = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http") {
            text = "http://" + text
        }
        return URL(string: text)
    }

    /// 保存设置：先落盘、再验证连通性，验证通过立刻切到主界面，
    /// 列表数据随后在后台补齐，不让用户对着配置页干等三个请求。
    func saveSettings() async {
        guard let url = normalizedURL else {
            lastError = "地址格式不正确"
            return
        }
        baseURLText = url.absoluteString
        UserDefaults.standard.set(baseURLText, forKey: Self.urlKey)

        // token 存 Keychain + 容器兜底文件，落盘失败直接报错，不进入主界面
        guard TokenStore.save(tokenText) else {
            lastError = "token 保存失败，请检查钥匙串权限"
            return
        }
        guard let client else {
            lastError = "token 不能为空"
            return
        }

        // 健康检查最快，先用它验证地址与 token 是否正确
        do {
            health = try await client.health()
        } catch {
            health = nil
            lastError = error.localizedDescription
            return
        }

        // 验证通过：置位持久化标记，界面带过渡动画切走
        if !configured {
            UserDefaults.standard.set(true, forKey: Self.configuredKey)
            configured = true
        }
        // 项目与任务列表在后台补齐，ProjectsView 有骨架占位，不会闪空白
        Task { await self.refresh() }
    }

    /// 首次进入时拉一次数据
    func bootstrap() async {
        guard isConfigured else { return }
        await refresh()
    }

    /// 刷新健康状态、项目与任务列表。
    /// 启动与回到前台可能同时触发，这里合并成一次，避免重复请求和加载状态闪烁。
    func refresh() async {
        if let running = inFlightRefresh {
            await running.value
            return
        }
        guard let client else { return }
        isLoading = true
        let task = Task { await self.loadAll(client: client) }
        inFlightRefresh = task
        await task.value
        inFlightRefresh = nil
        isLoading = false
    }

    /// 多个接口并发请求但分别落地：
    /// 任一接口抖动只影响自己那一块，不会让整页变成空白等用户下拉刷新。
    private func loadAll(client: APIClient) async {
        async let hTask = client.health()
        async let pTask = client.projects()
        async let tTask = client.tasks()
        async let progTask = client.programs()
        async let sysTask = client.systemInfo()

        var firstError: String?
        do {
            health = try await hTask
        } catch {
            health = nil
            firstError = error.localizedDescription
        }
        do {
            projects = try await pTask
        } catch {
            if firstError == nil { firstError = error.localizedDescription }
        }
        do {
            tasks = try await tTask
        } catch {
            if firstError == nil { firstError = error.localizedDescription }
        }
        do {
            let result = try await progTask
            programs = result.programs
            // 按内存占用从高到低，方便一眼看出吃资源的应用
            runningApps = result.running.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
        } catch {
            if firstError == nil { firstError = error.localizedDescription }
        }
        do {
            systemInfo = try await sysTask
        } catch {
            if firstError == nil { firstError = error.localizedDescription }
        }
        lastError = firstError
    }

    /// 只刷新本机程序与系统信息
    func refreshPrograms() async {
        guard let client else { return }
        async let progTask = client.programs()
        async let sysTask = client.systemInfo()
        var firstError: String?
        do {
            let result = try await progTask
            programs = result.programs
            runningApps = result.running.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
        } catch {
            firstError = error.localizedDescription
        }
        do {
            systemInfo = try await sysTask
        } catch {
            if firstError == nil { firstError = error.localizedDescription }
        }
        lastError = firstError
    }

    /// 切换受管程序开关
    func toggleProgram(_ program: ProgramStatus) async {
        guard let client else { return }
        do {
            if program.running {
                try await client.stopProgram(id: program.id)
            } else {
                try await client.startProgram(id: program.id)
            }
            // 稍等让进程状态落稳再刷
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refreshPrograms()
        } catch {
            lastError = error.localizedDescription
            await refreshPrograms()
        }
    }

    /// 退出正在运行的应用
    func quitRunningApp(_ app: RunningApp) async {
        guard let client else { return }
        do {
            try await client.quitApp(name: app.name)
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refreshPrograms()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 打开 Applications 里的应用
    func openAvailableApp(_ app: AvailableApp) async throws {
        guard let client else { throw APIError(error: "尚未配置服务器") }
        try await client.openApp(path: app.path)
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refreshPrograms()
    }

    /// 远程调节亮度（0~100），并回写本地 systemInfo.display
    func setBrightness(percent: Int) async throws {
        guard let client else { throw APIError(error: "尚未配置服务器") }
        let display = try await client.setBrightness(percent: percent)
        // Optional struct 不能通过 ?. 原地改字段，需整份写回
        if var info = systemInfo {
            info.display = display
            systemInfo = info
        }
    }

    /// 远程调节音量；muted 为 nil 时保持原静音状态
    func setVolume(percent: Int, muted: Bool? = nil) async throws {
        guard let client else { throw APIError(error: "尚未配置服务器") }
        let audio = try await client.setVolume(percent: percent, muted: muted)
        if var info = systemInfo {
            info.audio = audio
            systemInfo = info
        }
    }

    /// 只刷新任务列表（任务跑动期间用）
    func refreshTasks() async {
        // 已有全量刷新在跑就等它，避免两批请求同时打服务端
        if let running = inFlightRefresh {
            await running.value
            return
        }
        guard let client else { return }
        if let list = try? await client.tasks() {
            tasks = list
        }
    }

    /// 新建任务
    func createTask(project: ProjectInfo, prompt: String, mode: String, model: String, approval: String) async throws -> TaskInfo {
        guard let client else { throw APIError(error: "尚未配置服务器") }
        let detail = try await client.createTask(
            project: project.name,
            prompt: prompt,
            mode: mode,
            model: model,
            approval: approval
        )
        await refreshTasks()
        return detail.info
    }

    /// 清空配置（回到设置引导页）
    func signOut() {
        TokenStore.clear()
        UserDefaults.standard.removeObject(forKey: Self.urlKey)
        UserDefaults.standard.removeObject(forKey: Self.configuredKey)
        configured = false
        tokenText = ""
        // 退登后回到默认地址，不留下空白输入框
        baseURLText = Self.defaultBaseURL
        health = nil
        projects = []
        tasks = []
        programs = []
        runningApps = []
        systemInfo = nil
    }
}
