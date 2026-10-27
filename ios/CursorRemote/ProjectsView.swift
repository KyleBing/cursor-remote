import SwiftUI

/// 项目列表：点项目直接发起对话
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var newTaskProject: ProjectInfo?
    @State private var path: [TaskInfo] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let health = model.health {
                    Section { ServerStatusRow(health: health) }
                }

                if let error = model.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("项目") {
                    if model.projects.isEmpty {
                        Text(model.isLoading ? "加载中…" : "没有可用项目")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.projects) { project in
                        Button {
                            newTaskProject = project
                        } label: {
                            ProjectRow(project: project)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("远程 Cursor")
            .refreshable { await model.refresh() }
            .navigationDestination(for: TaskInfo.self) { task in
                TaskDetailView(task: task)
            }
            .sheet(item: $newTaskProject) { project in
                NewTaskView(project: project) { created in
                    newTaskProject = nil
                    path.append(created)
                }
            }
        }
    }
}

/// 任务历史列表
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [TaskInfo] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.tasks.isEmpty {
                    Text(model.isLoading ? "加载中…" : "还没有任务")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.tasks) { task in
                    NavigationLink(value: task) {
                        TaskRow(task: task)
                    }
                }
            }
            .navigationTitle("任务")
            .refreshable { await model.refreshTasks() }
            .task { await model.refreshTasks() }
            .navigationDestination(for: TaskInfo.self) { task in
                TaskDetailView(task: task)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshTasks() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
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
