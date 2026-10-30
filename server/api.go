package main

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Server 持有配置与任务管理器，负责全部 HTTP 接口。
type Server struct {
	cfg *Config
	mgr *Manager

	cfgMu      sync.Mutex // 保护 projects 白名单的读写与落盘
	healthMu   sync.Mutex
	healthAt   time.Time
	healthBody map[string]any
}

// NewServer 构造 HTTP 服务。
func NewServer(cfg *Config, mgr *Manager) *Server {
	return &Server{cfg: cfg, mgr: mgr}
}

// Routes 注册全部路由。
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", s.auth(s.handleHealth))
	mux.HandleFunc("GET /api/projects", s.auth(s.handleProjects))
	mux.HandleFunc("POST /api/projects", s.auth(s.handleAddProject))
	mux.HandleFunc("POST /api/projects/sync", s.auth(s.handleSyncProjects))
	mux.HandleFunc("DELETE /api/projects", s.auth(s.handleRemoveProject))
	mux.HandleFunc("GET /api/tasks", s.auth(s.handleListTasks))
	mux.HandleFunc("POST /api/tasks", s.auth(s.handleCreateTask))
	mux.HandleFunc("GET /api/tasks/{id}", s.auth(s.handleGetTask))
	mux.HandleFunc("GET /api/tasks/{id}/stream", s.auth(s.handleStream))
	mux.HandleFunc("POST /api/tasks/{id}/stop", s.auth(s.handleStop))
	mux.HandleFunc("POST /api/tasks/{id}/followup", s.auth(s.handleFollowUp))
	// 本机程序：白名单启停 + 正在运行 / 可打开的 GUI 应用
	mux.HandleFunc("GET /api/programs", s.auth(s.handleListPrograms))
	mux.HandleFunc("POST /api/programs/{id}/start", s.auth(s.handleStartProgram))
	mux.HandleFunc("POST /api/programs/{id}/stop", s.auth(s.handleStopProgram))
	mux.HandleFunc("GET /api/apps", s.auth(s.handleListApps))
	mux.HandleFunc("GET /api/apps/available", s.auth(s.handleAvailableApps))
	mux.HandleFunc("POST /api/apps/open", s.auth(s.handleOpenApp))
	mux.HandleFunc("POST /api/apps/quit", s.auth(s.handleQuitApp))
	mux.HandleFunc("GET /api/system", s.auth(s.handleSystemInfo))
	mux.HandleFunc("POST /api/system/brightness", s.auth(s.handleSetBrightness))
	mux.HandleFunc("POST /api/system/volume", s.auth(s.handleSetVolume))
	// 根路径给个简单说明页，方便用浏览器自测。
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprint(w, "cursor-remote server 正在运行\n\n接口前缀: /api\n")
	})
	return mux
}

// auth 校验 Bearer token。
// 同时也接受 ?token=，但仅限本机回环地址，避免公网场景下 token 落进访问日志。
func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok := ""
		if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
			tok = strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
		}
		if tok == "" && isLoopback(r) {
			tok = r.URL.Query().Get("token")
		}
		if subtle.ConstantTimeCompare([]byte(tok), []byte(s.cfg.Token)) != 1 {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next(w, r)
	}
}

// isLoopback 判断请求是否来自本机。
func isLoopback(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// writeJSON 输出 JSON 响应。
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// handleHealth 返回服务与 CLI 的可用状态。
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	s.healthMu.Lock()
	defer s.healthMu.Unlock()

	// CLI 状态探测有成本，缓存 60 秒。
	if s.healthBody == nil || time.Since(s.healthAt) > 60*time.Second {
		body := map[string]any{
			"ok":        true,
			"agentPath": s.cfg.AgentPath,
			"version":   "",
			"loggedIn":  false,
			"detail":    "",
			"projects":  len(s.cfg.Projects),
			"time":      time.Now().UnixMilli(),
		}
		if s.cfg.AgentPath == "" {
			body["detail"] = "未找到 agent CLI"
		} else {
			// 用 CombinedOutput 一并拿到 stderr，便于定位失败原因
			if out, err := exec.Command(s.cfg.AgentPath, "--version").CombinedOutput(); err == nil {
				body["version"] = strings.TrimSpace(string(out))
			} else {
				body["detail"] = "agent --version 执行失败: " + err.Error() + " / " + strings.TrimSpace(string(out))
			}
			// agent status 未登录时输出 Not logged in。
			if out, err := exec.Command(s.cfg.AgentPath, "status").CombinedOutput(); err == nil {
				txt := strings.ToLower(string(out))
				loggedIn := !strings.Contains(txt, "not logged in") && strings.TrimSpace(string(out)) != ""
				body["loggedIn"] = loggedIn
				if !loggedIn && body["detail"] == "" {
					body["detail"] = "CLI 未登录，请在 Mac 上执行 agent login"
				}
			} else if body["detail"] == "" {
				body["detail"] = "agent status 执行失败: " + err.Error()
			}
		}
		s.healthBody = body
		s.healthAt = time.Now()
	}
	writeJSON(w, http.StatusOK, s.healthBody)
}

// handleProjects 返回白名单项目及其会话统计。
func (s *Server) handleProjects(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"projects": s.projectInfos()})
}

// projectInfos 在锁内拷贝白名单并附带会话统计。
func (s *Server) projectInfos() []ProjectInfo {
	s.cfgMu.Lock()
	defer s.cfgMu.Unlock()
	out := make([]ProjectInfo, 0, len(s.cfg.Projects))
	for _, p := range s.cfg.Projects {
		sessions, last := projectStatsFor(p.Path)
		out = append(out, ProjectInfo{Name: p.Name, Path: p.Path, Sessions: sessions, LastActive: last})
	}
	return out
}

// invalidateHealthCache 项目数变化后清掉健康检查缓存。
func (s *Server) invalidateHealthCache() {
	s.healthMu.Lock()
	s.healthBody = nil
	s.healthMu.Unlock()
}

// addProjectReq 是手动添加白名单项目的请求体。
type addProjectReq struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// handleAddProject 按绝对路径（或 ~ 路径）加入白名单。
func (s *Server) handleAddProject(w http.ResponseWriter, r *http.Request) {
	var req addProjectReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "请求体不是合法 JSON"})
		return
	}
	if strings.TrimSpace(req.Path) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "缺少 path"})
		return
	}
	s.cfgMu.Lock()
	proj, added, err := s.cfg.addProject(req.Name, req.Path)
	s.cfgMu.Unlock()
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if added {
		s.invalidateHealthCache()
	}
	sessions, last := projectStatsFor(proj.Path)
	writeJSON(w, http.StatusOK, map[string]any{
		"added":   added,
		"project": ProjectInfo{Name: proj.Name, Path: proj.Path, Sessions: sessions, LastActive: last},
		"projects": s.projectInfos(),
	})
}

// handleSyncProjects 从 Cursor CLI 状态合并新项目到白名单。
func (s *Server) handleSyncProjects(w http.ResponseWriter, r *http.Request) {
	s.cfgMu.Lock()
	added, err := s.cfg.syncProjectsFromCLI()
	s.cfgMu.Unlock()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if len(added) > 0 {
		s.invalidateHealthCache()
	}
	addedInfo := make([]ProjectInfo, 0, len(added))
	for _, p := range added {
		sessions, last := projectStatsFor(p.Path)
		addedInfo = append(addedInfo, ProjectInfo{Name: p.Name, Path: p.Path, Sessions: sessions, LastActive: last})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"added":    addedInfo,
		"addedCount": len(addedInfo),
		"projects": s.projectInfos(),
	})
}

// removeProjectReq 按名称或路径移除白名单项。
type removeProjectReq struct {
	Project string `json:"project"`
	Path    string `json:"path"`
	Name    string `json:"name"`
}

// handleRemoveProject 从白名单删除项目（不删磁盘目录）。
func (s *Server) handleRemoveProject(w http.ResponseWriter, r *http.Request) {
	var req removeProjectReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "请求体不是合法 JSON"})
		return
	}
	key := strings.TrimSpace(req.Project)
	if key == "" {
		key = strings.TrimSpace(req.Path)
	}
	if key == "" {
		key = strings.TrimSpace(req.Name)
	}
	s.cfgMu.Lock()
	removed, ok, err := s.cfg.removeProject(key)
	s.cfgMu.Unlock()
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "白名单中没有该项目: " + key})
		return
	}
	s.invalidateHealthCache()
	writeJSON(w, http.StatusOK, map[string]any{
		"removed":  removed,
		"projects": s.projectInfos(),
	})
}

// handleListTasks 返回任务列表。
func (s *Server) handleListTasks(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 {
		limit = 50
	}
	writeJSON(w, http.StatusOK, map[string]any{"tasks": s.mgr.List(limit)})
}

// createTaskReq 是新建任务的请求体。
type createTaskReq struct {
	Project  string `json:"project"` // 项目名或绝对路径
	Prompt   string `json:"prompt"`
	Mode     string `json:"mode"`     // agent | plan | ask
	Model    string `json:"model"`    // 空表示用账号默认
	Approval string `json:"approval"` // default | auto-review | force
}

// handleCreateTask 新建并启动任务。
func (s *Server) handleCreateTask(w http.ResponseWriter, r *http.Request) {
	var req createTaskReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "请求体不是合法 JSON"})
		return
	}
	// 只允许白名单内的项目，避免远程执行任意目录。
	s.cfgMu.Lock()
	proj, ok := s.cfg.projectByName(req.Project)
	if !ok {
		proj, ok = s.cfg.projectByPath(req.Project)
	}
	s.cfgMu.Unlock()
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "项目不在白名单内: " + req.Project})
		return
	}
	mode := strings.ToLower(strings.TrimSpace(req.Mode))
	if mode != "plan" && mode != "ask" {
		mode = "agent"
	}
	approval := s.cfg.normalizeApproval(req.Approval)
	t, err := s.mgr.Start(proj, req.Prompt, mode, strings.TrimSpace(req.Model), approval)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	detail := t.Detail()
	stripRaw(&detail)
	writeJSON(w, http.StatusOK, detail)
}

// taskByID 从路径里取任务。
func (s *Server) taskByID(r *http.Request) *Task {
	return s.mgr.Get(r.PathValue("id"))
}

// stripRaw 去掉事件里的 raw 字段，减少传输体积。
func stripRaw(d *TaskDetail) {
	for i := range d.Events {
		d.Events[i].Raw = nil
	}
}

// handleGetTask 返回任务详情（含全部事件）。
// 默认剥掉 raw（只用于服务端复盘），?raw=1 可取回完整原始行。
func (s *Server) handleGetTask(w http.ResponseWriter, r *http.Request) {
	t := s.taskByID(r)
	if t == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "任务不存在"})
		return
	}
	detail := t.Detail()
	if r.URL.Query().Get("raw") != "1" {
		stripRaw(&detail)
	}
	writeJSON(w, http.StatusOK, detail)
}

// handleStop 中断任务。
func (s *Server) handleStop(w http.ResponseWriter, r *http.Request) {
	t := s.taskByID(r)
	if t == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "任务不存在"})
		return
	}
	if !s.mgr.Stop(t) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "任务未在运行"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "stopping"})
}

// handleFollowUp 在已有会话上继续对话。
func (s *Server) handleFollowUp(w http.ResponseWriter, r *http.Request) {
	t := s.taskByID(r)
	if t == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "任务不存在"})
		return
	}
	var req struct {
		Prompt string `json:"prompt"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Prompt) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "prompt 不能为空"})
		return
	}
	if err := s.mgr.FollowUp(t, req.Prompt); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "started"})
}

// handleStream 用 SSE 推送任务事件，支持 ?after=N 断点续传。
func (s *Server) handleStream(w http.ResponseWriter, r *http.Request) {
	t := s.taskByID(r)
	if t == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "任务不存在"})
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "不支持流式响应"})
		return
	}

	after, _ := strconv.Atoi(r.URL.Query().Get("after"))
	ch, replay, unsub := t.Subscribe(after)
	defer unsub()

	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	// 首帧带上任务元信息，断线重连也能立刻恢复状态。
	writeSSE(w, flusher, "task", t.Info())
	for _, e := range replay {
		writeSSE(w, flusher, "event", e)
	}
	flusher.Flush()

	// 任务已结束则直接收尾，避免客户端挂着一个空连接。
	info := t.Info()
	if info.Status != StatusRunning && info.Status != StatusQueued {
		writeSSE(w, flusher, "done", map[string]string{"status": info.Status})
		return
	}

	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case e, ok := <-ch:
			if !ok {
				return
			}
			writeSSE(w, flusher, "event", e)
			if e.Type == "status" && e.Text != StatusRunning && e.Text != StatusQueued {
				writeSSE(w, flusher, "done", map[string]string{"status": e.Text})
				return
			}
		case <-heartbeat.C:
			// 心跳用 SSE 注释行，客户端会忽略。
			fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		case <-r.Context().Done():
			return
		}
	}
}

// handleListPrograms 返回白名单程序状态，并附带当前前台应用列表。
func (s *Server) handleListPrograms(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"programs": listProgramStatuses(s.cfg),
		"running":  listRunningApps(),
	})
}

// handleSystemInfo 返回本机硬件 / 内存 / 磁盘 / 网络 / 蓝牙 / 亮度音量电池等。
func (s *Server) handleSystemInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, collectSystemInfo())
}

// handleSetBrightness 远程调节亮度，body: {"percent":0-100}。
func (s *Server) handleSetBrightness(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Percent *int `json:"percent"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Percent == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "需要 percent（0~100）"})
		return
	}
	d, err := setBrightnessPercent(*req.Percent)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "display": d})
}

// handleSetVolume 远程调节音量，body: {"percent":0-100,"muted":bool?}。
func (s *Server) handleSetVolume(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Percent *int  `json:"percent"`
		Muted   *bool `json:"muted"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Percent == nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "需要 percent（0~100）"})
		return
	}
	a, err := setVolume(*req.Percent, req.Muted)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "audio": a})
}

// handleStartProgram 启动白名单内的程序。
func (s *Server) handleStartProgram(w http.ResponseWriter, r *http.Request) {
	p, ok := s.cfg.programByID(r.PathValue("id"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "程序不在白名单内"})
		return
	}
	if err := startProgram(p); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "started", "program": p.ID})
}

// handleStopProgram 关闭白名单内的程序。
func (s *Server) handleStopProgram(w http.ResponseWriter, r *http.Request) {
	p, ok := s.cfg.programByID(r.PathValue("id"))
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "程序不在白名单内"})
		return
	}
	if err := stopProgram(p); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "stopped", "program": p.ID})
}

// handleListApps 只返回正在运行的前台 GUI 应用。
func (s *Server) handleListApps(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"apps": listRunningApps()})
}

// handleAvailableApps 返回 Applications 目录里可打开的应用。
func (s *Server) handleAvailableApps(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"apps": listAvailableApps()})
}

// handleOpenApp 打开应用：优先 path（须在 Applications 下），否则按 name。
func (s *Server) handleOpenApp(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "请求体不是合法 JSON"})
		return
	}
	var err error
	switch {
	case strings.TrimSpace(req.Path) != "":
		err = openAppPath(req.Path)
	case strings.TrimSpace(req.Name) != "":
		err = openApp(req.Name)
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name 不能为空"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "opened"})
}

// handleQuitApp 退出正在运行的前台应用。
func (s *Server) handleQuitApp(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
		PID  int    `json:"pid"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "请求体不是合法 JSON"})
		return
	}
	var err error
	switch {
	case strings.TrimSpace(req.Name) != "":
		err = quitApp(req.Name)
	case req.PID > 0:
		err = quitAppByPID(req.PID)
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name 不能为空"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "quit"})
}

// writeSSE 输出一条 SSE 帧。
// Event 里的 raw 只用于本地落盘复盘，推给客户端会让流量成倍放大，这里剥掉。
func writeSSE(w http.ResponseWriter, f http.Flusher, name string, v any) {
	if e, ok := v.(Event); ok && e.Raw != nil {
		e.Raw = nil
		v = e
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "event: %s\ndata: %s\n\n", name, raw)
	f.Flush()
}
