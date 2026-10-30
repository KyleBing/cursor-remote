import SwiftUI

// MARK: - 通用小工具

extension String {
    /// 去掉首尾空白
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 把服务端的状态字符串映射成颜色
func statusColor(_ status: String) -> Color {
    switch status {
    case "running": return .blue
    case "done": return .green
    case "failed": return .red
    case "stopped": return .orange
    default: return .secondary
    }
}

/// 状态胶囊
struct StatusChip: View {
    let status: String

    var body: some View {
        Text(TaskStatusStyle.label(status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor(status).opacity(0.16), in: Capsule())
            .foregroundStyle(statusColor(status))
    }
}

// MARK: - 项目行

struct ProjectRow: View {
    let project: ProjectInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.headline)
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text("\(project.sessions) 个会话")
                    Text("·")
                    Text(project.lastActiveText)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.quaternary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

// MARK: - 任务行

struct TaskRow: View {
    let task: TaskInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.project)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                StatusChip(status: task.status)
            }
            Text(task.prompt)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(task.createdDate, format: .dateTime.month().day().hour().minute())
                if !task.durationText.isEmpty {
                    Text("·")
                    Text(task.durationText)
                }
                if let e = task.error, !e.isEmpty {
                    Text("·")
                    Text(e).lineLimit(1).foregroundStyle(.red)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 服务端状态行

struct ServerStatusRow: View {
    let health: Health

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(health.loggedIn == true ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(health.loggedIn == true ? "Mac 在线 · CLI 已登录" : "Mac 在线 · CLI 未登录")
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = health.version, !v.isEmpty { parts.append("agent \(v)") }
        if let d = health.detail, !d.isEmpty { parts.append(d) }
        if let p = health.projects { parts.append("\(p) 个项目") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 事件块

struct BlockRow: View {
    let block: Block
    @State private var thinkingExpanded = false

    var body: some View {
        switch block.kind {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.circle.fill").foregroundStyle(.tint)
                Text(block.text)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

        case .assistant:
            // Agent 正文按 markdown 渲染：代码块、列表、标题、表格等
            MarkdownView(text: block.text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking:
            // 思考过程默认只露一两行，点开可看全文
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    thinkingExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis.bubble")
                            .font(.caption2)
                        Text(thinkingExpanded ? "思考过程" : thinkingPreview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(thinkingExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: thinkingExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if thinkingExpanded {
                    Text(block.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .files:
            VStack(alignment: .leading, spacing: 8) {
                Text("修改的文件")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(block.files) { file in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(file.name)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("+\(file.add)")
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.green)
                        Text("−\(file.del)")
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

        case .info:
            Text(block.text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .error:
            Text(block.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// 折叠时的一两行摘要（取末尾，更接近当前思路）
    private var thinkingPreview: String {
        let oneLine = block.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.isEmpty { return "思考中…" }
        if oneLine.count <= 80 { return oneLine }
        return "…" + String(oneLine.suffix(80))
    }
}
