package main

import (
	"strings"
	"testing"
)

func TestBuildArgsDashPromptIsNotParsedAsFlag(t *testing.T) {
	m := &Manager{cfg: &Config{}}
	task := &Task{info: TaskInfo{ProjectPath: "/tmp/demo", SessionID: "sess-1"}}

	args := m.buildArgs(task, "- 这是纯文本列表项", "ask", "auto", "auto-review", true)

	// prompt 必须在 -- 之后，避免 agent CLI 把 "- ..." 当成未知选项
	sep := -1
	for i, a := range args {
		if a == "--" {
			sep = i
			break
		}
	}
	if sep < 0 {
		t.Fatalf("缺少 -- 分隔符: %v", args)
	}
	if sep+1 >= len(args) || args[sep+1] != "- 这是纯文本列表项" {
		t.Fatalf("-- 后应为完整 prompt，得到: %v", args[sep:])
	}
	for _, a := range args[:sep] {
		if strings.HasPrefix(a, "- ") {
			t.Fatalf("选项区不应出现以 - 开头的 prompt 片段: %v", args)
		}
	}
}
