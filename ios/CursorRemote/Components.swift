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
    @State private var expanded = false

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

        case .tool:
            DisclosureGroup(isExpanded: $expanded) {
                Text(block.detail?.isEmpty == false ? block.detail! : "（无参数）")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: toolIcon(block.tool))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(block.tool ?? "tool")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                    if block.running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(8)
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

    /// 按工具名挑图标
    private func toolIcon(_ tool: String?) -> String {
        switch tool {
        case "shell": return "terminal"
        case "read": return "doc.text"
        case "edit", "write": return "square.and.pencil"
        case "grep", "search": return "magnifyingglass"
        case "delete": return "trash"
        default: return "wrench.and.screwdriver"
        }
    }
}
