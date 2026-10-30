package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

// maxRaw 限制原始事件落盘体积，避免工具输出把事件文件撑爆。
const maxRaw = 4000

// handleLine 解析 agent CLI 的一行 stream-json 输出并转成事件。
// 格式与 Claude Code 兼容：system/user/assistant/tool_call/result 等。
func (t *Task) handleLine(line string) {
	line = strings.TrimRight(line, "\r")
	trimmed := strings.TrimSpace(line)
	if trimmed == "" {
		return
	}
	if !strings.HasPrefix(trimmed, "{") {
		t.emit(Event{Type: "stdout", Text: trimmed})
		return
	}

	var m map[string]any
	if err := json.Unmarshal([]byte(trimmed), &m); err != nil {
		t.emit(Event{Type: "stdout", Text: trimmed})
		return
	}

	// 记录 session id，供 --resume 续接。
	if sid, ok := m["session_id"].(string); ok && sid != "" {
		t.setSession(sid)
	}

	typ, _ := m["type"].(string)
	sub, _ := m["subtype"].(string)

	var raw json.RawMessage
	if len(trimmed) <= maxRaw {
		raw = json.RawMessage(trimmed)
	}

	switch typ {
	case "system":
		if sub == "init" {
			model, _ := m["model"].(string)
			cwd, _ := m["cwd"].(string)
			t.setModel(model)
			t.emit(Event{Type: "info", Sub: "init", Text: fmt.Sprintf("会话就绪 · 模型 %s · %s", model, cwd), Raw: raw})
			return
		}
		t.emit(Event{Type: "info", Sub: sub, Text: "system: " + sub, Raw: raw})

	case "user":
		// CLI 会回显用户输入，App 已有原文，这里不重复渲染。
		txt := extractText(m["message"])
		if txt == "" {
			return
		}
		t.emit(Event{Type: "user", Text: txt})

	case "assistant":
		txt := extractText(m["message"])
		if txt == "" {
			return
		}
		// 累积一份纯文本，作为没有 result 事件时的兜底结果。
		t.mu.Lock()
		t.result.WriteString(txt)
		t.mu.Unlock()
		t.emit(Event{Type: "assistant", Text: txt, Raw: raw})

	case "thinking":
		// 思考过程：正文在顶层 text 字段（不是 message.content）。
		txt, _ := m["text"].(string)
		if txt == "" && sub != "completed" {
			return
		}
		t.emit(Event{Type: "thinking", Sub: sub, Text: txt, Raw: raw})

	case "tool_call":
		callID, _ := m["call_id"].(string)
		tool, detail := describeTool(m["tool_call"])
		t.emit(Event{Type: "tool_call", Sub: sub, CallID: callID, Tool: tool, Detail: detail, Raw: raw})

	case "result":
		isErr, _ := m["is_error"].(bool)
		res, _ := m["result"].(string)
		if res != "" {
			t.setResult(res)
		}
		note := ""
		if isErr {
			note = "执行失败"
		}
		if d, ok := m["duration_ms"].(float64); ok {
			note = strings.TrimSpace(fmt.Sprintf("%s 用时 %.1fs", note, d/1000))
		}
		t.emit(Event{Type: "result", Sub: sub, Text: note, Detail: res, Raw: raw})

	case "interaction_query":
		qt, _ := m["query_type"].(string)
		if sub == "request" {
			t.emit(Event{Type: "info", Sub: "approval", Text: "需要确认: " + qt, Raw: raw})
		}

	case "retry", "connection":
		t.emit(Event{Type: "info", Sub: typ, Text: fmt.Sprintf("%s: %s", typ, sub), Raw: raw})

	case "usage":
		return

	default:
		if typ == "" {
			t.emit(Event{Type: "stdout", Text: trimmed})
			return
		}
		txt := extractText(m["message"])
		if txt == "" {
			txt = typ
			if sub != "" {
				txt += ": " + sub
			}
		}
		t.emit(Event{Type: "info", Sub: typ, Text: txt, Raw: raw})
	}
}

// extractText 从 message.content 中拼接所有 text 块。
func extractText(message any) string {
	msg, ok := message.(map[string]any)
	if !ok {
		return ""
	}
	blocks, ok := msg["content"].([]any)
	if !ok {
		if s, ok := msg["content"].(string); ok {
			return s
		}
		return ""
	}
	var b strings.Builder
	for _, blk := range blocks {
		bm, ok := blk.(map[string]any)
		if !ok {
			continue
		}
		if bm["type"] == "text" {
			if s, ok := bm["text"].(string); ok {
				b.WriteString(s)
			}
		}
	}
	return b.String()
}

// describeTool 从 tool_call 载荷里提取工具名与参数摘要。
// 载荷形如 {"shellToolCall": {"args": {"command": "ls"}}}。
// 对 edit/write/delete：只保留路径与增减行数，不把正文塞进 detail（省流量、方便 App 汇总）。
func describeTool(v any) (tool, detail string) {
	m, ok := v.(map[string]any)
	if !ok {
		return "", ""
	}
	for k, val := range m {
		if !strings.HasSuffix(k, "ToolCall") {
			continue
		}
		tool = strings.TrimSuffix(k, "ToolCall")
		vm, _ := val.(map[string]any)
		args, _ := vm["args"].(map[string]any)
		switch tool {
		case "edit", "write", "delete":
			detail = summarizeFileChange(tool, args, vm)
		default:
			if args != nil {
				detail = compactJSON(args)
			} else if vm != nil {
				detail = compactJSON(vm)
			} else {
				detail = compactJSON(val)
			}
		}
		break
	}
	return tool, detail
}

// summarizeFileChange 把改文件类工具压成 {path,add,del}，供详情页列文件列表。
func summarizeFileChange(tool string, args, vm map[string]any) string {
	out := map[string]any{"path": "", "add": 0, "del": 0}
	if args != nil {
		if p, ok := args["path"].(string); ok {
			out["path"] = p
		}
	}
	add, del := 0, 0
	// 优先用 result 里的统计（若 CLI 提供）
	if vm != nil {
		if res, ok := vm["result"].(map[string]any); ok {
			add = anyInt(res["linesAdded"], res["addedLines"], res["add"])
			del = anyInt(res["linesRemoved"], res["removedLines"], res["del"])
		}
	}
	if add == 0 && del == 0 && args != nil {
		switch tool {
		case "delete":
			del = 1
		case "write", "edit":
			if s, ok := args["streamContent"].(string); ok {
				add = countLines(s)
			} else if s, ok := args["contents"].(string); ok {
				add = countLines(s)
			} else if s, ok := args["new_string"].(string); ok {
				add = countLines(s)
				if old, ok := args["old_string"].(string); ok {
					del = countLines(old)
				}
			}
		}
	}
	out["add"] = add
	out["del"] = del
	return compactJSON(out)
}

// anyInt 从候选字段里取第一个非零整数（JSON 数字常为 float64）。
func anyInt(vals ...any) int {
	for _, v := range vals {
		switch n := v.(type) {
		case float64:
			if n != 0 {
				return int(n)
			}
		case int:
			if n != 0 {
				return n
			}
		case int64:
			if n != 0 {
				return int(n)
			}
		case json.Number:
			if i, err := n.Int64(); err == nil && i != 0 {
				return int(i)
			}
		}
	}
	return 0
}

// countLines 按换行计行数；空串为 0，无换行的非空串计 1 行。
func countLines(s string) int {
	if s == "" {
		return 0
	}
	n := strings.Count(s, "\n")
	if strings.HasSuffix(s, "\n") {
		return n
	}
	return n + 1
}

// compactJSON 把任意值压成单行 JSON，超长截断。
func compactJSON(v any) string {
	if v == nil {
		return ""
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprint(v)
	}
	s := string(raw)
	if len(s) > maxRaw {
		s = s[:maxRaw] + "…"
	}
	return s
}
