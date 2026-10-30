package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestDescribeToolFileSummary 确认 edit/write 只输出路径与行数，不含正文。
func TestDescribeToolFileSummary(t *testing.T) {
	payload := map[string]any{
		"editToolCall": map[string]any{
			"args": map[string]any{
				"path":          "/tmp/demo.swift",
				"streamContent": "a\nb\nc\n",
			},
		},
	}
	tool, detail := describeTool(payload)
	if tool != "edit" {
		t.Fatalf("tool=%q", tool)
	}
	if strings.Contains(detail, "streamContent") {
		t.Fatalf("detail 不应含正文: %s", detail)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(detail), &m); err != nil {
		t.Fatal(err)
	}
	if m["path"] != "/tmp/demo.swift" {
		t.Fatalf("path=%v", m["path"])
	}
	if int(m["add"].(float64)) != 3 {
		t.Fatalf("add=%v want 3", m["add"])
	}
}

// TestCountLines 覆盖空串、单行、末尾换行。
func TestCountLines(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"", 0},
		{"x", 1},
		{"a\nb", 2},
		{"a\nb\n", 2},
		{"a\nb\nc\n", 3},
	}
	for _, c := range cases {
		if got := countLines(c.in); got != c.want {
			t.Fatalf("countLines(%q)=%d want %d", c.in, got, c.want)
		}
	}
}

// TestThinkingAndEditParse 走 handleLine，确认 thinking 正文与 edit 摘要入事件。
func TestThinkingAndEditParse(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := ensureDirs(); err != nil {
		t.Fatal(err)
	}
	task, err := newTask(TaskInfo{ID: "t-parse", Project: "demo", Status: StatusRunning})
	if err != nil {
		t.Fatal(err)
	}
	defer task.file.Close()

	task.handleLine(`{"type":"thinking","subtype":"delta","text":"先看布局"}`)
	task.handleLine(`{"type":"thinking","subtype":"delta","text":"再改尺寸"}`)
	task.handleLine(`{"type":"tool_call","subtype":"completed","call_id":"e1","tool_call":{"editToolCall":{"args":{"path":"/tmp/A.swift","streamContent":"one\ntwo\n"}}}}`)

	detail := task.Detail()
	var thinking, edit string
	for _, e := range detail.Events {
		switch e.Type {
		case "thinking":
			thinking += e.Text
		case "tool_call":
			edit = e.Detail
		}
	}
	if thinking != "先看布局再改尺寸" {
		t.Fatalf("thinking=%q", thinking)
	}
	if !strings.Contains(edit, `"/tmp/A.swift"`) || !strings.Contains(edit, `"add":2`) {
		t.Fatalf("edit detail=%q", edit)
	}
}
