package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// stubAgentScript 模拟 agent CLI 的 stream-json 输出，用于端到端验证。
// 用 printf 逐行输出，避免 heredoc 依赖临时文件（受限环境下会失败）。
const stubAgentScript = `#!/bin/bash
printf '%s\n' \
  '{"type":"system","subtype":"init","model":"stub-model","cwd":"/tmp","session_id":"sess-1","permissionMode":"default"}' \
  '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"session_id":"sess-1"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"你"}]},"session_id":"sess-1"}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"好"}]},"session_id":"sess-1"}' \
  '{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"shellToolCall":{"args":{"command":"ls -la"}}},"session_id":"sess-1"}' \
  '{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"shellToolCall":{"args":{"command":"ls -la"}}},"session_id":"sess-1"}' \
  '{"type":"result","subtype":"success","duration_ms":1234,"is_error":false,"result":"你好","session_id":"sess-1"}'
`

// newTestServer 构造一个使用临时 HOME 与 stub agent 的服务实例。
func newTestServer(t *testing.T) (*Server, *Config, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)

	projDir := filepath.Join(home, "demo-project")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatal(err)
	}
	agentPath := filepath.Join(home, "stub-agent.sh")
	if err := os.WriteFile(agentPath, []byte(stubAgentScript), 0o755); err != nil {
		t.Fatal(err)
	}

	cfg := &Config{
		Port:            0,
		Token:           "test-token",
		AgentPath:       agentPath,
		Projects:        []Project{{Name: "demo", Path: projDir}},
		DefaultApproval: "auto-review",
		path:            filepath.Join(home, "config.json"),
	}
	if err := ensureDirs(); err != nil {
		t.Fatal(err)
	}
	mgr, err := NewManager(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return NewServer(cfg, mgr), cfg, projDir
}

// doReq 发起一次带鉴权的请求。
func doReq(t *testing.T, s *Server, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
	}
	r.Header.Set("Authorization", "Bearer test-token")
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, r)
	return w
}

// TestAuth 未带 token 时必须拒绝。
func TestAuth(t *testing.T) {
	s, _, _ := newTestServer(t)
	r := httptest.NewRequest("GET", "/api/projects", nil)
	// 显式设为非回环地址，模拟公网请求
	r.RemoteAddr = "203.0.113.9:51234"
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("期望 401，实际 %d", w.Code)
	}
}

// TestAuthRejectsQueryTokenFromPublic 公网请求不允许用 ?token= 传凭据。
func TestAuthRejectsQueryTokenFromPublic(t *testing.T) {
	s, _, _ := newTestServer(t)
	r := httptest.NewRequest("GET", "/api/projects?token=test-token", nil)
	r.RemoteAddr = "203.0.113.9:51234"
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("公网带 ?token= 应被拒绝，实际 %d", w.Code)
	}

	// 本机回环调试则允许
	r2 := httptest.NewRequest("GET", "/api/projects?token=test-token", nil)
	r2.RemoteAddr = "127.0.0.1:51234"
	w2 := httptest.NewRecorder()
	s.Routes().ServeHTTP(w2, r2)
	if w2.Code != http.StatusOK {
		t.Fatalf("本机带 ?token= 应放行，实际 %d", w2.Code)
	}
}

// TestProjects 校验项目列表与统计字段。
func TestProjects(t *testing.T) {
	s, _, projDir := newTestServer(t)
	w := doReq(t, s, "GET", "/api/projects", "")
	if w.Code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d: %s", w.Code, w.Body.String())
	}
	var resp struct {
		Projects []ProjectInfo `json:"projects"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Projects) != 1 || resp.Projects[0].Path != projDir {
		t.Fatalf("项目列表不符: %+v", resp.Projects)
	}
}

// TestAddAndSyncProjects 校验手动添加与 CLI 状态同步。
func TestAddAndSyncProjects(t *testing.T) {
	s, cfg, _ := newTestServer(t)
	home := os.Getenv("HOME")
	extra := filepath.Join(home, "extra-project")
	if err := os.MkdirAll(extra, 0o755); err != nil {
		t.Fatal(err)
	}

	// 手动添加
	body := fmt.Sprintf(`{"path":%q}`, extra)
	w := doReq(t, s, "POST", "/api/projects", body)
	if w.Code != http.StatusOK {
		t.Fatalf("添加失败 %d: %s", w.Code, w.Body.String())
	}
	var addResp struct {
		Added    bool          `json:"added"`
		Projects []ProjectInfo `json:"projects"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &addResp); err != nil {
		t.Fatal(err)
	}
	if !addResp.Added || len(addResp.Projects) != 2 {
		t.Fatalf("添加结果不符: %+v", addResp)
	}

	// 写入 CLI 状态，再同步第三个项目
	cliProj := filepath.Join(home, "cli-project")
	if err := os.MkdirAll(cliProj, 0o755); err != nil {
		t.Fatal(err)
	}
	cursorDir := filepath.Join(home, ".cursor")
	if err := os.MkdirAll(cursorDir, 0o755); err != nil {
		t.Fatal(err)
	}
	state := []byte(`{"workerIdsByDisplayName":{"~/cli-project @ Test Machine":"abc"}}`)
	if err := os.WriteFile(filepath.Join(cursorDir, "agent-cli-state.json"), state, 0o600); err != nil {
		t.Fatal(err)
	}
	w = doReq(t, s, "POST", "/api/projects/sync", "")
	if w.Code != http.StatusOK {
		t.Fatalf("同步失败 %d: %s", w.Code, w.Body.String())
	}
	var syncResp struct {
		AddedCount int           `json:"addedCount"`
		Projects   []ProjectInfo `json:"projects"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &syncResp); err != nil {
		t.Fatal(err)
	}
	if syncResp.AddedCount != 1 || len(syncResp.Projects) != 3 {
		t.Fatalf("同步结果不符: %+v cfg=%+v", syncResp, cfg.Projects)
	}

	// 删除
	w = doReq(t, s, "DELETE", "/api/projects", `{"path":"`+extra+`"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("删除失败 %d: %s", w.Code, w.Body.String())
	}
}

// TestTaskLifecycle 验证从建任务到事件解析、状态流转的完整链路。
func TestTaskLifecycle(t *testing.T) {
	s, _, _ := newTestServer(t)

	w := doReq(t, s, "POST", "/api/tasks", `{"project":"demo","prompt":"嗨","mode":"ask"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("建任务失败 %d: %s", w.Code, w.Body.String())
	}
	var created TaskDetail
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}

	// 等待 stub 进程结束。
	var detail TaskDetail
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		w = doReq(t, s, "GET", "/api/tasks/"+created.ID, "")
		if err := json.Unmarshal(w.Body.Bytes(), &detail); err != nil {
			t.Fatal(err)
		}
		if detail.Status == StatusDone || detail.Status == StatusFailed {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	if detail.Status != StatusDone {
		t.Fatalf("期望 done，实际 %s (%s)", detail.Status, detail.Error)
	}
	if detail.Result != "你好" {
		t.Fatalf("result 不符: %q", detail.Result)
	}
	if detail.Model != "stub-model" {
		t.Fatalf("model 不符: %q", detail.Model)
	}
	if detail.SessionID != "sess-1" {
		t.Fatalf("sessionID 不符: %q", detail.SessionID)
	}

	var assistant, tool string
	for _, e := range detail.Events {
		switch e.Type {
		case "assistant":
			assistant += e.Text
		case "tool_call":
			if e.Sub == "started" {
				tool = e.Tool + " " + e.Detail
			}
		}
	}
	if assistant != "你好" {
		t.Fatalf("assistant 事件拼接不符: %q", assistant)
	}
	if !strings.Contains(tool, "shell") || !strings.Contains(tool, "ls -la") {
		t.Fatalf("tool_call 解析不符: %q", tool)
	}
}

// TestHealth 校验健康检查能正确反映 CLI 状态。
func TestHealth(t *testing.T) {
	s, _, _ := newTestServer(t)
	w := doReq(t, s, "GET", "/api/health", "")
	if w.Code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d: %s", w.Code, w.Body.String())
	}
	var h struct {
		LoggedIn bool `json:"loggedIn"`
		Projects int  `json:"projects"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &h); err != nil {
		t.Fatal(err)
	}
	// stub agent 会输出 JSON，因此被视为"已登录"
	if !h.LoggedIn {
		t.Fatalf("期望 loggedIn=true，实际 %+v，原始响应: %s", h, w.Body.String())
	}
	if h.Projects != 1 {
		t.Fatalf("项目数不符: %d", h.Projects)
	}
}

// TestCreateTaskRejectsUnknownProject 白名单外的路径必须拒绝。
func TestCreateTaskRejectsUnknownProject(t *testing.T) {
	s, _, _ := newTestServer(t)
	w := doReq(t, s, "POST", "/api/tasks", `{"project":"/etc","prompt":"x"}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("期望 400，实际 %d", w.Code)
	}
}

// TestStreamSSE 校验 SSE 首帧与结束帧。
func TestStreamSSE(t *testing.T) {
	s, _, _ := newTestServer(t)
	w := doReq(t, s, "POST", "/api/tasks", `{"project":"demo","prompt":"嗨"}`)
	var created TaskDetail
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	// 等任务结束，SSE 会直接回放并收尾。
	time.Sleep(700 * time.Millisecond)

	sw := doReq(t, s, "GET", "/api/tasks/"+created.ID+"/stream", "")
	body := sw.Body.String()
	if !strings.Contains(body, "event: task") {
		t.Fatalf("缺少 task 首帧: %s", body)
	}
	if !strings.Contains(body, "event: done") {
		t.Fatalf("缺少 done 帧: %s", body)
	}
	if ct := sw.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("Content-Type 不符: %s", ct)
	}

	// 每一帧都应是合法 JSON，且不该携带 raw（它只用于本地复盘，会放大流量）
	sc := bufio.NewScanner(strings.NewReader(body))
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "data: ") {
			var v map[string]any
			if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &v); err != nil {
				t.Fatalf("SSE data 不是合法 JSON: %s", line)
			}
			if _, hasRaw := v["raw"]; hasRaw {
				t.Fatalf("SSE 不应推送 raw 字段: %s", line)
			}
		}
	}
}
