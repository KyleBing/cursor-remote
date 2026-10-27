package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// 任务状态取值。
const (
	StatusQueued  = "queued"
	StatusRunning = "running"
	StatusDone    = "done"
	StatusFailed  = "failed"
	StatusStopped = "stopped"
)

// Event 是一条归一化后的对话事件，App 直接按此渲染。
type Event struct {
	Seq    int             `json:"seq"`
	At     int64           `json:"at"` // 毫秒时间戳
	Type   string          `json:"type"`
	Sub    string          `json:"sub,omitempty"`
	Text   string          `json:"text,omitempty"`
	Tool   string          `json:"tool,omitempty"`
	CallID string          `json:"callID,omitempty"`
	Detail string          `json:"detail,omitempty"`
	Raw    json.RawMessage `json:"raw,omitempty"`
}

// TaskInfo 是任务的元信息（落盘为 meta.json）。
type TaskInfo struct {
	ID          string `json:"id"`
	Project     string `json:"project"`
	ProjectPath string `json:"projectPath"`
	Prompt      string `json:"prompt"`
	Mode        string `json:"mode"`
	Model       string `json:"model,omitempty"`
	Approval    string `json:"approval"`
	SessionID   string `json:"sessionID,omitempty"`
	Status      string `json:"status"`
	CreatedAt   int64  `json:"createdAt"`
	StartedAt   int64  `json:"startedAt,omitempty"`
	EndedAt     int64  `json:"endedAt,omitempty"`
	ExitCode    *int   `json:"exitCode,omitempty"`
	Result      string `json:"result,omitempty"`
	Error       string `json:"error,omitempty"`
}

// TaskDetail 是任务详情，附带完整事件流。
type TaskDetail struct {
	TaskInfo
	Events []Event `json:"events"`
}

// Task 是一个正在或已经执行过的 agent 会话。
type Task struct {
	mu   sync.Mutex
	info TaskInfo

	dir    string
	seq    int
	events []Event
	subs   map[chan Event]struct{}
	file   *os.File

	cancel  func()
	result  strings.Builder // 累积助手正文，作为 result 兜底
	lastSub bool
}

// newTask 创建任务对象并写好目录。
func newTask(info TaskInfo) (*Task, error) {
	dir := filepath.Join(tasksDir(), info.ID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dir, "events.jsonl"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return nil, err
	}
	t := &Task{info: info, dir: dir, subs: map[chan Event]struct{}{}, file: f}
	t.saveMeta()
	return t, nil
}

// loadTask 从磁盘恢复任务（保留事件流，便于回家复盘）。
func loadTask(dir string) (*Task, error) {
	raw, err := os.ReadFile(filepath.Join(dir, "meta.json"))
	if err != nil {
		return nil, err
	}
	var info TaskInfo
	if err := json.Unmarshal(raw, &info); err != nil {
		return nil, err
	}
	t := &Task{info: info, dir: dir, subs: map[chan Event]struct{}{}}
	t.result.WriteString(info.Result)

	// 回读事件流；末尾半行（进程被强杀时可能出现）直接丢弃。
	f, err := os.Open(filepath.Join(dir, "events.jsonl"))
	if err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
		for sc.Scan() {
			var e Event
			if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
				continue
			}
			t.events = append(t.events, e)
			if e.Seq > t.seq {
				t.seq = e.Seq
			}
		}
	}
	// 上次没跑完就退出的任务，标记为失败。
	if t.info.Status == StatusRunning || t.info.Status == StatusQueued {
		t.info.Status = StatusFailed
		t.info.Error = "服务重启，任务已中断"
		t.saveMeta()
	}
	return t, nil
}

// saveMeta 写出任务元信息。
func (t *Task) saveMeta() {
	raw, err := json.MarshalIndent(t.info, "", "  ")
	if err != nil {
		return
	}
	tmp := filepath.Join(t.dir, "meta.json.tmp")
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return
	}
	_ = os.Rename(tmp, filepath.Join(t.dir, "meta.json"))
}

// Info 返回元信息快照。
func (t *Task) Info() TaskInfo {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.info
}

// Detail 返回元信息与事件流快照。
func (t *Task) Detail() TaskDetail {
	t.mu.Lock()
	defer t.mu.Unlock()
	evs := make([]Event, len(t.events))
	copy(evs, t.events)
	return TaskDetail{TaskInfo: t.info, Events: evs}
}

// EventsAfter 返回 seq 大于 after 的事件，用于断线重连补齐。
func (t *Task) EventsAfter(after int) []Event {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]Event, 0, len(t.events))
	for _, e := range t.events {
		if e.Seq > after {
			out = append(out, e)
		}
	}
	return out
}

// Subscribe 订阅实时事件，同时回放 after 之后的历史事件。
func (t *Task) Subscribe(after int) (<-chan Event, []Event, func()) {
	t.mu.Lock()
	defer t.mu.Unlock()
	ch := make(chan Event, 512)
	t.subs[ch] = struct{}{}
	replay := make([]Event, 0, 32)
	for _, e := range t.events {
		if e.Seq > after {
			replay = append(replay, e)
		}
	}
	unsub := func() {
		t.mu.Lock()
		defer t.mu.Unlock()
		if _, ok := t.subs[ch]; ok {
			delete(t.subs, ch)
			close(ch)
		}
	}
	return ch, replay, unsub
}

// emit 追加一条事件：落盘、缓存、广播。
func (t *Task) emit(e Event) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.seq++
	e.Seq = t.seq
	if e.At == 0 {
		e.At = time.Now().UnixMilli()
	}
	t.events = append(t.events, e)
	if t.file != nil {
		if raw, err := json.Marshal(e); err == nil {
			_, _ = t.file.Write(append(raw, '\n'))
		}
	}
	for ch := range t.subs {
		select {
		case ch <- e:
		default: // 客户端太慢就丢，重连时用 after 补齐
		}
	}
}

// setStatus 更新状态并广播一条 status 事件。
func (t *Task) setStatus(status, errMsg string) {
	t.mu.Lock()
	t.info.Status = status
	if errMsg != "" {
		t.info.Error = errMsg
	}
	if status != StatusRunning && status != StatusQueued {
		t.info.EndedAt = time.Now().UnixMilli()
	}
	t.saveMeta()
	t.mu.Unlock()

	t.emit(Event{Type: "status", Text: status})
}

// setSession 记录 CLI 返回的 session id，供后续 --resume 继续对话。
func (t *Task) setSession(id string) {
	t.mu.Lock()
	if t.info.SessionID == id {
		t.mu.Unlock()
		return
	}
	t.info.SessionID = id
	t.saveMeta()
	t.mu.Unlock()
}

// setModel 记录实际使用的模型名。
func (t *Task) setModel(model string) {
	if model == "" {
		return
	}
	t.mu.Lock()
	t.info.Model = model
	t.saveMeta()
	t.mu.Unlock()
}

// setResult 保存最终结果文本。
func (t *Task) setResult(s string) {
	if s == "" {
		return
	}
	t.mu.Lock()
	t.info.Result = s
	t.saveMeta()
	t.mu.Unlock()
}

// closeFile 关闭事件文件。
func (t *Task) closeFile() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.file != nil {
		_ = t.file.Close()
		t.file = nil
	}
}

// openEventsFile 以追加方式重新打开事件文件，续聊时需要。
func (t *Task) openEventsFile() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.file != nil {
		return
	}
	f, err := os.OpenFile(filepath.Join(t.dir, "events.jsonl"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err == nil {
		t.file = f
	}
}

// beginRun 把任务切到新一轮执行的状态。
func (t *Task) beginRun() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.info.Status = StatusRunning
	t.info.StartedAt = time.Now().UnixMilli()
	t.info.EndedAt = 0
	t.info.ExitCode = nil
	t.info.Error = ""
	t.info.Result = ""
	t.result.Reset()
	t.saveMeta()
}

// Manager 管理全部任务。
type Manager struct {
	cfg   *Config
	mu    sync.Mutex
	tasks map[string]*Task
	order []string // 按创建时间倒序
}

// NewManager 恢复历史任务。
func NewManager(cfg *Config) (*Manager, error) {
	m := &Manager{cfg: cfg, tasks: map[string]*Task{}}
	ents, err := os.ReadDir(tasksDir())
	if err != nil {
		if os.IsNotExist(err) {
			return m, nil
		}
		return nil, err
	}
	type pair struct {
		info TaskInfo
		task *Task
	}
	var all []pair
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		t, err := loadTask(filepath.Join(tasksDir(), e.Name()))
		if err != nil {
			continue
		}
		m.tasks[t.info.ID] = t
		all = append(all, pair{t.info, t})
	}
	// 按创建时间倒序排列 id。
	for i := 0; i < len(all); i++ {
		for j := i + 1; j < len(all); j++ {
			if all[j].info.CreatedAt > all[i].info.CreatedAt {
				all[i], all[j] = all[j], all[i]
			}
		}
	}
	for _, p := range all {
		m.order = append(m.order, p.info.ID)
	}
	return m, nil
}

// Get 按 id 取任务。
func (m *Manager) Get(id string) *Task {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.tasks[id]
}

// List 返回任务摘要列表。
func (m *Manager) List(limit int) []TaskInfo {
	m.mu.Lock()
	ids := append([]string(nil), m.order...)
	m.mu.Unlock()

	if limit <= 0 || limit > len(ids) {
		limit = len(ids)
	}
	out := make([]TaskInfo, 0, limit)
	for _, id := range ids[:limit] {
		if t := m.Get(id); t != nil {
			out = append(out, t.Info())
		}
	}
	return out
}

// Start 新建任务并异步拉起 agent 进程。
func (m *Manager) Start(proj Project, prompt, mode, model, approval string) (*Task, error) {
	if strings.TrimSpace(prompt) == "" {
		return nil, fmt.Errorf("prompt 不能为空")
	}
	id := fmt.Sprintf("%d-%s", time.Now().Unix(), randHex(4))
	info := TaskInfo{
		ID:          id,
		Project:     proj.Name,
		ProjectPath: proj.Path,
		Prompt:      prompt,
		Mode:        mode,
		Model:       model,
		Approval:    approval,
		Status:      StatusQueued,
		CreatedAt:   time.Now().UnixMilli(),
	}
	t, err := newTask(info)
	if err != nil {
		return nil, err
	}

	m.mu.Lock()
	m.tasks[id] = t
	m.order = append([]string{id}, m.order...)
	m.mu.Unlock()

	go m.run(t, prompt, mode, model, approval, false)
	return t, nil
}

// FollowUp 在已有会话上追加一轮指令（--resume）。
func (m *Manager) FollowUp(t *Task, prompt string) error {
	base := t.Info()
	if base.SessionID == "" {
		return fmt.Errorf("该任务没有可续接的会话")
	}
	projPath := base.ProjectPath
	if _, ok := m.cfg.projectByPath(projPath); !ok {
		return fmt.Errorf("项目不在白名单内")
	}
	t.mu.Lock()
	t.info.Status = StatusRunning
	t.saveMeta()
	t.mu.Unlock()
	t.emit(Event{Type: "user", Text: prompt})
	go m.run(t, prompt, base.Mode, base.Model, base.Approval, true)
	return nil
}

// Stop 请求中断任务。
func (m *Manager) Stop(t *Task) bool {
	t.mu.Lock()
	cancel := t.cancel
	t.mu.Unlock()
	if cancel == nil {
		return false
	}
	cancel()
	return true
}

// buildArgs 组装 agent CLI 参数。
func (m *Manager) buildArgs(t *Task, prompt, mode, model, approval string, resume bool) []string {
	args := []string{
		"-p",
		"--output-format", "stream-json",
		"--stream-partial-output",
		"--workspace", t.info.ProjectPath,
		"--trust",
	}
	if resume && t.info.SessionID != "" {
		args = append(args, "--resume", t.info.SessionID)
	}
	switch mode {
	case "plan", "ask":
		args = append(args, "--mode", mode)
	}
	if model != "" && model != "auto" {
		args = append(args, "--model", model)
	}
	switch approval {
	case "force":
		args = append(args, "--force")
	case "default":
		// 不传开关，走 CLI 本地默认策略
	default:
		args = append(args, "--auto-review")
	}
	args = append(args, m.cfg.ExtraArgs...)
	args = append(args, prompt)
	return args
}

// run 执行一次 agent 调用并把输出流式转成事件。
func (m *Manager) run(t *Task, prompt, mode, model, approval string, resume bool) {
	if m.cfg.AgentPath == "" {
		t.setStatus(StatusFailed, "未找到 agent CLI，请先安装 Cursor CLI 并执行 agent login")
		return
	}

	// 只有持有锁的地方会读、写 cancel；这里用局部变量再赋值。
	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, m.cfg.AgentPath, m.buildArgs(t, prompt, mode, model, approval, resume)...)
	cmd.Dir = t.info.ProjectPath
	cmd.Env = append(os.Environ(), "NO_COLOR=1", "TERM=dumb", "CI=1")
	// 先发 SIGINT 让 agent 自行收尾，超时后由 WaitDelay 强制杀。
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return cmd.Process.Signal(syscall.SIGINT)
	}
	cmd.WaitDelay = 8 * time.Second

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		t.setStatus(StatusFailed, "无法连接 agent 输出: "+err.Error())
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		cancel()
		t.setStatus(StatusFailed, "无法连接 agent 错误流: "+err.Error())
		return
	}
	if err := cmd.Start(); err != nil {
		cancel()
		t.setStatus(StatusFailed, "启动 agent 失败: "+err.Error())
		return
	}

	// 续聊时事件文件已关闭，这里重新打开以便继续落盘。
	t.openEventsFile()
	t.mu.Lock()
	t.cancel = cancel
	t.mu.Unlock()
	t.beginRun()
	t.emit(Event{Type: "status", Text: StatusRunning})

	// stderr 作为 error 事件推给 App，方便看登录失效之类的问题。
	go func() {
		sc := bufio.NewScanner(stderr)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			line := strings.TrimRight(sc.Text(), "\r")
			if strings.TrimSpace(line) == "" {
				continue
			}
			t.emit(Event{Type: "stderr", Text: line})
		}
	}()

	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for sc.Scan() {
		t.handleLine(sc.Text())
	}
	scanErr := sc.Err()

	waitErr := cmd.Wait()
	// 必须在 cancel 之前判断，否则 ctx.Err() 恒为非空。
	stopped := ctx.Err() != nil
	cancel()
	t.closeFile()
	// 结束后清掉取消句柄，避免 Stop 误判为仍在运行
	t.mu.Lock()
	t.cancel = nil
	t.mu.Unlock()

	info := t.Info()
	switch {
	case stopped && waitErr != nil:
		t.setStatus(StatusStopped, "已手动停止")
	case waitErr != nil:
		msg := waitErr.Error()
		if scanErr != nil {
			msg += " (" + scanErr.Error() + ")"
		}
		t.setStatus(StatusFailed, msg)
	default:
		if info.Result == "" {
			// 没有 result 事件时，用累积的助手正文兜底。
			t.mu.Lock()
			fallback := strings.TrimSpace(t.result.String())
			t.mu.Unlock()
			if fallback != "" {
				t.setResult(fallback)
			}
		}
		t.setStatus(StatusDone, "")
	}
}
