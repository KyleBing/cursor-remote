import SwiftUI

/// 任务详情：实时事件流 + 停止 / 续聊
struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: TaskSession
    @State private var draft = ""

    init(task: TaskInfo) {
        _session = State(initialValue: TaskSession(info: task))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header

                ForEach(session.blocks) { block in
                    BlockRow(block: block)
                }

                if session.info.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(session.connectionText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                if let err = session.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .padding(.bottom, 8)
        }
        // 内容增长时始终贴住底部，符合看日志的习惯
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(session.info.project)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        if let client = model.client {
                            await session.reload(client: client)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            if let client = model.client {
                session.start(client: client)
            }
        }
        .onDisappear {
            session.stopStream()
        }
        .onChange(of: scenePhase) { _, phase in
            // 从后台回来时 SSE 大概率已断，重新订阅并补齐事件
            if phase == .active, session.info.isRunning, let client = model.client {
                session.restart(client: client)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusChip(status: session.info.status)
                if let m = session.info.model, !m.isEmpty {
                    Text(m)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !session.info.durationText.isEmpty {
                    Text(session.info.durationText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            Text(session.info.prompt)
                .font(.callout)
                .textSelection(.enabled)

            if let err = session.info.error, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Text(session.info.projectPath)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider()
        }
    }

    // MARK: - 底部操作条

    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            if session.info.isRunning {
                HStack {
                    Text(session.connectionText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        guard let client = model.client else { return }
                        Task { await session.stop(client: client) }
                    } label: {
                        Label("停止", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            } else if session.info.sessionID != nil {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("继续追问…", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(draft.trimmed.isEmpty || session.busy)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            } else {
                Text("该任务无法续聊")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
        }
        .background(.bar)
    }

    /// 发送后续指令
    private func send() {
        guard let client = model.client, !draft.trimmed.isEmpty else { return }
        let text = draft.trimmed
        draft = ""
        Task { await session.followUp(client: client, prompt: text) }
    }
}
