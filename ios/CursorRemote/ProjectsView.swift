import SwiftUI

/// 项目列表：点项目直接发起对话
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var newTaskProject: ProjectInfo?
    @State private var path: [TaskInfo] = []
    @State private var selectedTask: TaskInfo?
    @State private var syncing = false
    @State private var syncMessage: String?
    @State private var filter = ""

    // 按名称 / 路径本地过滤
    private var filteredProjects: [ProjectInfo] {
        let q = filter.trimmed.lowercased()
        guard !q.isEmpty else { return model.projects }
        return model.projects.filter {
            $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }

    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        // iPad：列表 + 任务详情分栏；手机：单栏导航栈
        if isRegular {
            NavigationSplitView {
                projectRoot(showsDetailPush: false)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
            } detail: {
                if let selectedTask {
                    NavigationStack {
                        TaskDetailView(task: selectedTask)
                            .id(selectedTask.id)
                    }
                } else {
                    ContentUnavailableView(
                        "选择项目发起对话",
                        systemImage: "folder.badge.plus",
                        description: Text("左侧点项目即可下发指令；创建后详情会显示在这里。")
                    )
                }
            }
        } else {
            NavigationStack(path: $path) {
                projectRoot(showsDetailPush: true)
                    .navigationDestination(for: TaskInfo.self) { task in
                        TaskDetailView(task: task)
                    }
            }
        }
    }

    /// 项目列表根（手机 / iPad 共用）
    @ViewBuilder
    private func projectRoot(showsDetailPush: Bool) -> some View {
        Group {
            if isRegular {
                // 宽屏用双列卡片，更好利用横向空间
                projectScrollGrid
            } else {
                projectPhoneList
            }
        }
        .navigationTitle("远程 Cursor")
        .searchable(text: $filter, prompt: "搜索项目")
        .refreshable { await model.refresh() }
        .task {
            if model.projects.isEmpty {
                await model.refresh()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await syncFromCLI() }
                } label: {
                    if syncing {
                        ProgressView()
                    } else {
                        Label("同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(syncing || model.client == nil)
            }
        }
        .sheet(item: $newTaskProject) { project in
            NewTaskView(project: project) { created in
                newTaskProject = nil
                if showsDetailPush {
                    path.append(created)
                } else {
                    selectedTask = created
                }
            }
            .adaptiveSheetIdealSize()
        }
    }

    private var projectPhoneList: some View {
        List {
            statusSections
            Section("项目") {
                projectRows
            }
        }
    }

    private var projectScrollGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let health = model.health {
                    ServerStatusRow(health: health)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if model.isLoading {
                    ServerStatusRow(health: .placeholder)
                        .redacted(reason: .placeholder)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let syncMessage {
                    Text(syncMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("项目")
                    .font(.title3.weight(.semibold))

                if model.projects.isEmpty {
                    emptyProjectsView
                } else if filteredProjects.isEmpty {
                    Text("没有匹配「\(filter.trimmed)」的项目")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(filteredProjects) { project in
                            Button {
                                newTaskProject = project
                            } label: {
                                ProjectRow(project: project)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var statusSections: some View {
        if let health = model.health {
            Section { ServerStatusRow(health: health) }
        } else if model.isLoading {
            Section {
                ServerStatusRow(health: .placeholder)
                    .redacted(reason: .placeholder)
            }
        }

        if let error = model.lastError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }

        if let syncMessage {
            Section {
                Text(syncMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var projectRows: some View {
        if model.projects.isEmpty {
            if model.isLoading {
                ForEach(0..<3, id: \.self) { _ in
                    ProjectRow(project: .placeholder)
                        .redacted(reason: .placeholder)
                }
            } else {
                Text("没有可用项目。可点右上角同步，从 Mac 上 Cursor CLI 最近用过的目录导入。")
                    .foregroundStyle(.secondary)
            }
        } else if filteredProjects.isEmpty {
            Text("没有匹配「\(filter.trimmed)」的项目")
                .foregroundStyle(.secondary)
        }
        ForEach(filteredProjects) { project in
            Button {
                newTaskProject = project
            } label: {
                ProjectRow(project: project)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var emptyProjectsView: some View {
        if model.isLoading {
            ForEach(0..<3, id: \.self) { _ in
                ProjectRow(project: .placeholder)
                    .redacted(reason: .placeholder)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else {
            Text("没有可用项目。可点右上角同步，从 Mac 上 Cursor CLI 最近用过的目录导入。")
                .foregroundStyle(.secondary)
        }
    }

    /// 把 Mac 上 Cursor CLI 出现过的目录合并进白名单
    private func syncFromCLI() async {
        syncing = true
        defer { syncing = false }
        do {
            let added = try await model.syncProjectsFromCLI()
            syncMessage = added == 0 ? "已是最新，没有新项目" : "已同步，新增 \(added) 个项目"
        } catch {
            syncMessage = error.localizedDescription
        }
    }
}

/// 任务历史列表
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [TaskInfo] = []
    // 用 id 选中，避免刷新后 TaskInfo 字段变化导致选中丢失
    @State private var selectedTaskID: String?

    private var isRegular: Bool { sizeClass == .regular }

    private var selectedTask: TaskInfo? {
        guard let selectedTaskID else { return nil }
        return model.tasks.first { $0.id == selectedTaskID }
    }

    var body: some View {
        if isRegular {
            // iPad：左列表右详情，少一次整页跳转
            NavigationSplitView {
                taskList(selectionEnabled: true)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 440)
            } detail: {
                if let selectedTask {
                    NavigationStack {
                        TaskDetailView(task: selectedTask)
                            // 仅切换任务时重建会话，列表刷新不打断 SSE
                            .id(selectedTask.id)
                    }
                } else {
                    ContentUnavailableView(
                        "选择任务",
                        systemImage: "list.bullet.rectangle",
                        description: Text("从左侧选一条任务查看流式输出与续聊。")
                    )
                }
            }
        } else {
            NavigationStack(path: $path) {
                taskList(selectionEnabled: false)
                    .navigationDestination(for: TaskInfo.self) { task in
                        TaskDetailView(task: task)
                    }
            }
        }
    }

    @ViewBuilder
    private func taskList(selectionEnabled: Bool) -> some View {
        List(selection: selectionEnabled ? $selectedTaskID : nil) {
            if model.tasks.isEmpty {
                if model.isLoading {
                    ForEach(0..<3, id: \.self) { _ in
                        TaskRow(task: .placeholder)
                            .redacted(reason: .placeholder)
                    }
                } else {
                    Text("还没有任务")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.tasks) { task in
                if selectionEnabled {
                    TaskRow(task: task)
                        .tag(task.id)
                } else {
                    NavigationLink(value: task) {
                        TaskRow(task: task)
                    }
                }
            }
        }
        .navigationTitle("任务")
        .refreshable { await model.refreshTasks() }
        .task { await model.refreshTasks() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refreshTasks() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onChange(of: model.tasks.map(\.id)) { _, ids in
            guard selectionEnabled, let selectedTaskID else { return }
            if !ids.contains(selectedTaskID) {
                self.selectedTaskID = nil
            }
        }
    }
}

/// 发起新对话
struct NewTaskView: View {
    let project: ProjectInfo
    var onCreated: (TaskInfo) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var mode = "agent"
    @State private var approval = "auto-review"
    @State private var modelName = ""
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("项目") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.headline)
                        Text(project.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section("指令") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 130)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("模式", selection: $mode) {
                        Text("执行").tag("agent")
                        Text("只读规划").tag("plan")
                        Text("问答").tag("ask")
                    }
                    .pickerStyle(.segmented)

                    Picker("审批", selection: $approval) {
                        Text("自动审查").tag("auto-review")
                        Text("CLI 默认").tag("default")
                        Text("全部放行").tag("force")
                    }
                } header: {
                    Text("执行方式")
                } footer: {
                    Text("自动审查由服务端分类器放行安全命令，其余会暂停等待；全部放行需要服务端配置里打开 allowForce。")
                }

                Section {
                    TextField("模型（留空用默认）", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("发起对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView()
                    } else {
                        Button("发送") { submit() }
                            .disabled(prompt.trimmed.isEmpty)
                    }
                }
            }
        }
    }

    /// 提交任务
    private func submit() {
        guard let client = model.client else { return }
        submitting = true
        error = nil
        Task {
            defer { submitting = false }
            do {
                // 直接调用客户端，拿回任务 id 后再交给上层跳转
                let detail = try await client.createTask(
                    project: project.name,
                    prompt: prompt.trimmed,
                    mode: mode,
                    model: modelName.trimmed,
                    approval: approval
                )
                await model.refreshTasks()
                onCreated(detail.info)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
