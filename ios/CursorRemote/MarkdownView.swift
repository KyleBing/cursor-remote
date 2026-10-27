import SwiftUI
import UIKit

// MARK: - 解析结果

/// markdown 解析后的一段内容
enum MDBlock: Hashable {
    /// 列表项：indent 是缩进层级（0 为顶层）
    struct ListItem: Hashable {
        var indent: Int
        var text: String
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case code(lang: String?, body: String)
    case bullet(items: [ListItem])
    case ordered(start: Int, items: [ListItem])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case divider
}

// MARK: - 解析器

/// 轻量 markdown 解析，只覆盖 Agent 输出里常见的语法。
/// 不追求完整规范，但必须容忍流式输出中途不完整的文本：未闭合的代码围栏一直吃到文末。
enum MDParser {
    static func parse(_ text: String) -> [MDBlock] {
        // 统一换行，避免 \r\n 干扰围栏与行首匹配
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var i = 0

        /// 段落用空行分隔，遇到其它块时先收尾
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // 空行：段落分界
            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // 代码围栏：未闭合时把剩余行全部当成代码
            if let fence = fenceMarker(line) {
                flushParagraph()
                let lang = line.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let candidate = lines[i]
                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    body.append(candidate)
                    i += 1
                }
                blocks.append(.code(lang: lang.isEmpty ? nil : lang, body: body.joined(separator: "\n")))
                continue
            }

            // 分隔线
            if isDivider(line) {
                flushParagraph()
                blocks.append(.divider)
                i += 1
                continue
            }

            // 标题
            if let (level, title) = heading(line) {
                flushParagraph()
                blocks.append(.heading(level: level, text: title))
                i += 1
                continue
            }

            // 引用：连续多行合并成一段
            if line.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = String(candidate.dropFirst())
                    if content.hasPrefix(" ") { content = String(content.dropFirst()) }
                    quoted.append(content)
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // 表格：当前行含 |，且下一行是 | --- | 分隔行
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.isEmpty || !candidate.contains("|") { break }
                    rows.append(tableCells(candidate))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // 列表：连续同类型条目合并成一个列表
            let bulletHead = bulletItem(raw)
            let orderedHead = orderedItem(raw)
            if bulletHead != nil || orderedHead != nil {
                flushParagraph()
                let ordered = orderedHead != nil
                var items: [MDBlock.ListItem] = []
                if let head = bulletHead { items.append(.init(indent: head.indent, text: head.text)) }
                if let head = orderedHead { items.append(.init(indent: head.indent, text: head.text)) }
                let start = orderedHead?.number ?? 1
                i += 1
                while i < lines.count {
                    let candidate = lines[i]
                    if !ordered, let bullet = bulletItem(candidate) {
                        items.append(.init(indent: bullet.indent, text: bullet.text))
                        i += 1
                    } else if ordered, let number = orderedItem(candidate) {
                        items.append(.init(indent: number.indent, text: number.text))
                        i += 1
                    } else if candidate.hasPrefix("  "), !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                        // 缩进续行并入上一条
                        items[items.count - 1].text += " " + candidate.trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(ordered ? .ordered(start: start, items: items) : .bullet(items: items))
                continue
            }

            // 普通段落行
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - 行级识别

    /// 代码围栏标记：``` 或 ~~~
    private static func fenceMarker(_ line: String) -> String? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) {
            return marker
        }
        return nil
    }

    /// 分隔线：至少三个 - * _
    private static func isDivider(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    /// 标题：# 到 ######，井号后必须跟空格
    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    /// 无序列表项
    private static func bulletItem(_ raw: String) -> (indent: Int, text: String)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (indentLevel(raw), String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// 有序列表项
    private static func orderedItem(_ raw: String) -> (indent: Int, number: Int, text: String)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let digits = line.prefix(while: { $0.isNumber })
        guard (1...3).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (indentLevel(raw), Int(digits) ?? 1, String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    /// 每两个空格（或一个 tab）算一层缩进，最多四层
    private static func indentLevel(_ raw: String) -> Int {
        var spaces = 0
        for ch in raw {
            if ch == " " { spaces += 1 } else if ch == "\t" { spaces += 2 } else { break }
        }
        return min(spaces / 2, 4)
    }

    /// 表格分隔行：只允许 - : | 和空格
    private static func isTableSeparator(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("-") else { return false }
        let allowed = CharacterSet(charactersIn: "-:| ")
        return line.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 拆表格一行，去掉首尾竖线
    private static func tableCells(_ raw: String) -> [String] {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") { line.removeFirst() }
        if line.hasSuffix("|") { line.removeLast() }
        return line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - 解析缓存

/// 流式输出会高频刷新，同一段文本常被重复求值，缓存解析结果省掉重复解析
@MainActor
private enum MDCache {
    private static var store: [String: [MDBlock]] = [:]
    private static var keys: [String] = []
    private static let limit = 12

    static func blocks(for text: String) -> [MDBlock] {
        if let hit = store[text] { return hit }
        let parsed = MDParser.parse(text)
        store[text] = parsed
        keys.append(text)
        if keys.count > limit {
            store.removeValue(forKey: keys.removeFirst())
        }
        return parsed
    }
}

// MARK: - 渲染

/// 把 Agent 返回的 markdown 渲染成 SwiftUI 视图
struct MarkdownView: View {
    let text: String

    var body: some View {
        // body 在 MainActor 上求值，缓存只在这里访问
        let blocks = MDCache.blocks(for: text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let title):
            mdInline(title)
                .font(headingFont(level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            mdInline(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let lang, let body):
            CodeBlockView(lang: lang, code: body)

        case .bullet(let items):
            listView(items: items, ordered: false, start: 1)

        case .ordered(let start, let items):
            listView(items: items, ordered: true, start: start)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                mdInline(text)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .table(let header, let rows):
            TableBlockView(header: header, rows: rows)

        case .divider:
            Divider()
        }
    }

    /// 标题字号
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    /// 列表：indent 层级用左内边距体现
    private func listView(items: [MDBlock.ListItem], ordered: Bool, start: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(start + index)." : "•")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                    mdInline(item.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.indent) * 14)
            }
        }
    }
}

/// 行内 markdown（粗体 / 斜体 / 行内代码 / 链接），解析失败退回纯文本
private func mdInline(_ string: String) -> Text {
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    if let attributed = try? AttributedString(markdown: string, options: options) {
        return Text(attributed)
    }
    return Text(string)
}

// MARK: - 代码块

/// 代码块：等宽字体、横向滚动、一键复制
private struct CodeBlockView: View {
    let lang: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(lang ?? "code")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    // 1.2 秒后恢复按钮文案
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 表格

/// 表格：Grid 自动对齐列宽，超宽时横向滚动
private struct TableBlockView: View {
    let header: [String]
    let rows: [[String]]

    /// 以表头列数为准，行尾缺的单元格补空
    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        mdInline(cell(header, column))
                            .font(.caption.weight(.semibold))
                    }
                }
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 0.5)
                    .gridCellColumns(columns)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            mdInline(cell(row, column))
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func cell(_ row: [String], _ index: Int) -> String {
        index < row.count ? row[index] : ""
    }
}
