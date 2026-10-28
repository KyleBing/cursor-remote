import Foundation

/// SSE 收到的一帧
enum StreamFrame {
    case task(TaskInfo)   // 任务元信息（含状态变化）
    case event(AgentEvent)
    case done(String)     // 服务端判定任务结束
}

/// 与 cursor-remote 服务端通信的客户端
struct APIClient {
    let baseURL: URL
    let token: String

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        // 不要缓存，SSE 必须实时
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 拼装带鉴权头的请求
    /// query 必须单独传：appendingPathComponent 会把 "?" 编码成 %3F，直接拼进 path 会丢查询参数
    private func request(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) -> URLRequest {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = query
            url = comps.url ?? url
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var req = URLRequest(url: comps?.url ?? url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// 统一发送并解码响应
    private func send<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) async throws -> T {
        let (data, response) = try await Self.session.data(for: request(path, method: method, body: body, query: query))
        guard let http = response as? HTTPURLResponse else {
            throw APIError(error: "无响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 优先用服务端返回的 error 字段
            if let apiErr = try? JSONDecoder().decode(APIError.self, from: data) {
                throw apiErr
            }
            throw APIError(error: "HTTP \(http.statusCode)")
        }
        if data.isEmpty { throw APIError(error: "响应为空") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - 接口

    func health() async throws -> Health {
        try await send("api/health")
    }

    func projects() async throws -> [ProjectInfo] {
        struct Wrapper: Decodable { let projects: [ProjectInfo] }
        let wrapper: Wrapper = try await send("api/projects")
        return wrapper.projects
    }

    func tasks(limit: Int = 50) async throws -> [TaskInfo] {
        struct Wrapper: Decodable { let tasks: [TaskInfo] }
        // limit 走 queryItems，不能拼进 path
        let wrapper: Wrapper = try await send("api/tasks", query: [URLQueryItem(name: "limit", value: String(limit))])
        return wrapper.tasks
    }

    func task(id: String) async throws -> TaskDetail {
        try await send("api/tasks/\(id)")
    }

    /// 新建任务
    func createTask(project: String, prompt: String, mode: String, model: String, approval: String) async throws -> TaskDetail {
        struct Body: Encodable {
            let project: String
            let prompt: String
            let mode: String
            let model: String
            let approval: String
        }
        let body = try JSONEncoder().encode(Body(project: project, prompt: prompt, mode: mode, model: model, approval: approval))
        return try await send("api/tasks", method: "POST", body: body)
    }

    /// 停止任务
    func stop(id: String) async throws {
        struct Wrapper: Decodable { let status: String }
        let _: Wrapper = try await send("api/tasks/\(id)/stop", method: "POST")
    }

    /// 续接对话
    func followUp(id: String, prompt: String) async throws {
        struct Body: Encodable { let prompt: String }
        struct Wrapper: Decodable { let status: String }
        let body = try JSONEncoder().encode(Body(prompt: prompt))
        let _: Wrapper = try await send("api/tasks/\(id)/followup", method: "POST", body: body)
    }

    // MARK: - 本机程序

    /// 受管程序 + 正在运行的前台应用
    func programs() async throws -> (programs: [ProgramStatus], running: [RunningApp]) {
        struct Wrapper: Decodable {
            let programs: [ProgramStatus]
            let running: [RunningApp]?
        }
        let wrapper: Wrapper = try await send("api/programs")
        return (wrapper.programs, wrapper.running ?? [])
    }

    /// 本机系统信息（硬件 / 内存 / 磁盘 / 网络 / 蓝牙 / 亮度音量电池）
    func systemInfo() async throws -> SystemInfo {
        try await send("api/system")
    }

    /// 调节亮度 0~100
    func setBrightness(percent: Int) async throws -> DisplayInfo {
        struct Body: Encodable { let percent: Int }
        struct Wrapper: Decodable {
            let status: String
            let display: DisplayInfo
        }
        let body = try JSONEncoder().encode(Body(percent: percent))
        let w: Wrapper = try await send("api/system/brightness", method: "POST", body: body)
        return w.display
    }

    /// 调节音量；muted 为 nil 表示不改静音状态
    func setVolume(percent: Int, muted: Bool? = nil) async throws -> AudioInfo {
        struct Body: Encodable {
            let percent: Int
            let muted: Bool?
        }
        struct Wrapper: Decodable {
            let status: String
            let audio: AudioInfo
        }
        let body = try JSONEncoder().encode(Body(percent: percent, muted: muted))
        let w: Wrapper = try await send("api/system/volume", method: "POST", body: body)
        return w.audio
    }

    /// 启动白名单程序
    func startProgram(id: String) async throws {
        struct Wrapper: Decodable { let status: String }
        let _: Wrapper = try await send("api/programs/\(id)/start", method: "POST")
    }

    /// 停止白名单程序
    func stopProgram(id: String) async throws {
        struct Wrapper: Decodable { let status: String }
        let _: Wrapper = try await send("api/programs/\(id)/stop", method: "POST")
    }

    /// Applications 目录可打开列表
    func availableApps() async throws -> [AvailableApp] {
        struct Wrapper: Decodable { let apps: [AvailableApp] }
        let wrapper: Wrapper = try await send("api/apps/available")
        return wrapper.apps
    }

    /// 打开应用（name 或 path 二选一）
    func openApp(name: String? = nil, path: String? = nil) async throws {
        struct Body: Encodable {
            let name: String?
            let path: String?
        }
        struct Wrapper: Decodable { let status: String }
        let body = try JSONEncoder().encode(Body(name: name, path: path))
        let _: Wrapper = try await send("api/apps/open", method: "POST", body: body)
    }

    /// 退出正在运行的前台应用
    func quitApp(name: String) async throws {
        struct Body: Encodable { let name: String }
        struct Wrapper: Decodable { let status: String }
        let body = try JSONEncoder().encode(Body(name: name))
        let _: Wrapper = try await send("api/apps/quit", method: "POST", body: body)
    }

    // MARK: - SSE

    /// 订阅任务事件流；after 为已收到的最后一个 seq，用于断线续传。
    func stream(id: String, after: Int) -> AsyncThrowingStream<StreamFrame, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    var req = request("api/tasks/\(id)/stream")
                    if after > 0 {
                        var comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                        comps?.queryItems = [URLQueryItem(name: "after", value: String(after))]
                        req.url = comps?.url
                    }
                    // SSE 是长连接，放大超时；服务端每 15 秒有心跳保活
                    req.timeoutInterval = 600

                    let (bytes, response) = try await Self.session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw APIError(error: "订阅失败 HTTP \(code)")
                    }

                    var eventName = ""
                    var dataBuffer = ""

                    // 逐行解析 SSE 帧
                    for try await line in bytes.lines {
                        if line.hasPrefix(":") { continue }        // 心跳注释
                        if line.isEmpty {
                            if !dataBuffer.isEmpty {
                                Self.decodeFrame(name: eventName, data: dataBuffer, into: continuation)
                            }
                            eventName = ""
                            dataBuffer = ""
                            continue
                        }
                        if line.hasPrefix("event: ") {
                            eventName = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            dataBuffer += String(line.dropFirst(6))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// 把一帧 SSE 数据解码成具体的 StreamFrame
    private static func decodeFrame(name: String, data: String, into continuation: AsyncThrowingStream<StreamFrame, Error>.Continuation) {
        guard let raw = data.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        switch name {
        case "task":
            if let info = try? decoder.decode(TaskInfo.self, from: raw) {
                continuation.yield(.task(info))
            }
        case "event":
            if let ev = try? decoder.decode(AgentEvent.self, from: raw) {
                continuation.yield(.event(ev))
            }
        case "done":
            struct Done: Decodable { let status: String }
            let status = (try? decoder.decode(Done.self, from: raw))?.status ?? "done"
            continuation.yield(.done(status))
        default:
            break
        }
    }
}
