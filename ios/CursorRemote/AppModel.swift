import Foundation
import Observation

/// 全局状态：服务器地址、token、项目与任务列表。
@Observable
final class AppModel {
    private static let urlKey = "cursorremote.baseURL"
    private static let tokenKey = "cursorremote.token"

    // 设置页绑定的输入值
    var baseURLText: String
    var tokenText: String

    // 运行态
    var health: Health?
    var projects: [ProjectInfo] = []
    var tasks: [TaskInfo] = []
    var isLoading = false
    var lastError: String?

    init() {
        baseURLText = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        tokenText = Keychain.get(Self.tokenKey) ?? ""
    }

    /// 是否已完成初始配置
    var isConfigured: Bool { client != nil }

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

    /// 保存设置并立刻试一次连接
    func saveSettings() async {
        guard let url = normalizedURL else {
            lastError = "地址格式不正确"
            return
        }
        baseURLText = url.absoluteString
        UserDefaults.standard.set(baseURLText, forKey: Self.urlKey)
        Keychain.set(tokenText, for: Self.tokenKey)
        await refresh()
    }

    /// 首次进入时拉一次数据
    func bootstrap() async {
        guard isConfigured else { return }
        await refresh()
    }

    /// 刷新健康状态、项目与任务列表
    func refresh() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let h = client.health()
            async let p = client.projects()
            async let t = client.tasks()
            health = try await h
            projects = try await p
            tasks = try await t
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            health = nil
        }
    }

    /// 只刷新任务列表（任务跑动期间用）
    func refreshTasks() async {
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
        Keychain.delete(Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.urlKey)
        tokenText = ""
        baseURLText = ""
        health = nil
        projects = []
        tasks = []
    }
}
