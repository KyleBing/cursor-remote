package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Program 是可被远程启停的白名单条目。
type Program struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Kind    string `json:"kind"`              // app | launchagent
	AppName string `json:"appName,omitempty"` // kind=app：open -a / quit 用的名称
	Label   string `json:"label,omitempty"`   // kind=launchagent：LaunchAgent label
}

// ProgramStatus 是带运行态的程序信息。
type ProgramStatus struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Kind        string `json:"kind"`
	Running     bool   `json:"running"`
	PID         int    `json:"pid,omitempty"`
	MemoryBytes int64  `json:"memoryBytes,omitempty"` // RSS
	Detail      string `json:"detail,omitempty"`
}

// RunningApp 是本机正在跑的前台 GUI 应用。
type RunningApp struct {
	Name        string `json:"name"`
	BundleID    string `json:"bundleId,omitempty"`
	PID         int    `json:"pid"`
	MemoryBytes int64  `json:"memoryBytes,omitempty"` // RSS
	Path        string `json:"path,omitempty"`
}

// AvailableApp 是 /Applications 里可打开的应用。
type AvailableApp struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// 不允许远程退出的系统关键进程。
var protectedAppNames = map[string]bool{
	"Finder": true, "Dock": true, "SystemUIServer": true,
	"WindowManager": true, "Control Center": true, "loginwindow": true,
	"Wallpaper": true, "NotificationCenter": true,
}

var (
	reAppHeader  = regexp.MustCompile(`^\s*\d+\)\s+"([^"]+)"`)
	reBundleID   = regexp.MustCompile(`bundleID="([^"]+)"`)
	reBundlePath = regexp.MustCompile(`bundle path="([^"]+)"`)
	rePIDType    = regexp.MustCompile(`pid = (\d+)\b[^"]*type="([^"]+)"`)
)

// defaultPrograms 首次配置时写入的常用受管程序。
func defaultPrograms() []Program {
	return []Program{
		{ID: "cursor", Name: "Cursor", Kind: "app", AppName: "Cursor"},
		{ID: "frpc", Name: "frp 隧道", Kind: "launchagent", Label: "cn.kylebing.cursor-remote-frpc"},
		{ID: "awake", Name: "防睡眠", Kind: "launchagent", Label: "cn.kylebing.cursor-remote-awake"},
	}
}

// isProtectedApp 判断是否为禁止远程关闭的系统应用。
func isProtectedApp(name string) bool {
	return protectedAppNames[name]
}

// programByID 按 id 查白名单。
func (c *Config) programByID(id string) (Program, bool) {
	for _, p := range c.Programs {
		if p.ID == id {
			return p, true
		}
	}
	return Program{}, false
}

// listProgramInfos 返回白名单程序的当前运行态（给 API 用）。
func (c *Config) listProgramInfos() []ProgramStatus {
	return listProgramStatuses(c)
}

// listProgramStatuses 返回白名单程序的当前运行态。
func listProgramStatuses(cfg *Config) []ProgramStatus {
	runningApps := listRunningApps()
	byName := map[string]RunningApp{}
	for _, a := range runningApps {
		byName[strings.ToLower(a.Name)] = a
	}
	rss := processRSSBytes()

	out := make([]ProgramStatus, 0, len(cfg.Programs))
	for _, p := range cfg.Programs {
		st := ProgramStatus{ID: p.ID, Name: p.Name, Kind: p.Kind}
		switch strings.ToLower(p.Kind) {
		case "launchagent":
			running, pid, detail := launchAgentState(p.Label)
			st.Running = running
			st.PID = pid
			st.Detail = detail
			if pid > 0 {
				st.MemoryBytes = rss[pid]
			}
		default: // app
			name := p.AppName
			if name == "" {
				name = p.Name
			}
			if a, ok := byName[strings.ToLower(name)]; ok {
				st.Running = true
				st.PID = a.PID
				st.Detail = a.Path
				st.MemoryBytes = a.MemoryBytes
			}
		}
		out = append(out, st)
	}
	return out
}

// startProgram 启动白名单程序。
func startProgram(p Program) error {
	switch strings.ToLower(p.Kind) {
	case "launchagent":
		if p.Label == "" {
			return fmt.Errorf("未配置 LaunchAgent label")
		}
		return startLaunchAgent(p.Label)
	default:
		name := p.AppName
		if name == "" {
			name = p.Name
		}
		return openApp(name)
	}
}

// stopProgram 关闭白名单程序。
func stopProgram(p Program) error {
	switch strings.ToLower(p.Kind) {
	case "launchagent":
		if p.Label == "" {
			return fmt.Errorf("未配置 LaunchAgent label")
		}
		return stopLaunchAgent(p.Label)
	default:
		name := p.AppName
		if name == "" {
			name = p.Name
		}
		return quitApp(name)
	}
}

// ---------- LaunchAgent ----------

func launchDomain() string {
	return fmt.Sprintf("gui/%d", os.Getuid())
}

func launchAgentPlist(label string) string {
	return filepath.Join(homeDir(), "Library/LaunchAgents", label+".plist")
}

// launchAgentState 读取 LaunchAgent 是否在跑。
func launchAgentState(label string) (running bool, pid int, detail string) {
	if label == "" {
		return false, 0, "未配置 label"
	}
	plist := launchAgentPlist(label)
	if _, err := os.Stat(plist); err != nil {
		return false, 0, "未安装（找不到 plist）"
	}
	out, err := exec.Command("launchctl", "print", launchDomain()+"/"+label).CombinedOutput()
	if err != nil {
		return false, 0, "未加载"
	}
	txt := string(out)
	running = strings.Contains(txt, "state = running")
	if m := regexp.MustCompile(`(?m)^\s*pid = (\d+)`).FindStringSubmatch(txt); len(m) == 2 {
		pid, _ = strconv.Atoi(m[1])
	}
	if running {
		detail = "running"
	} else if strings.Contains(txt, "state =") {
		detail = "已加载但未运行"
	} else {
		detail = "已加载"
	}
	return running, pid, detail
}

// startLaunchAgent 加载并拉起（KeepAlive 类服务用 bootstrap）。
func startLaunchAgent(label string) error {
	plist := launchAgentPlist(label)
	if _, err := os.Stat(plist); err != nil {
		return fmt.Errorf("未找到 %s，请先在本机安装对应 LaunchAgent", plist)
	}
	domain := launchDomain()
	_ = exec.Command("launchctl", "bootout", domain+"/"+label).Run()
	_ = exec.Command("launchctl", "bootout", domain, plist).Run()
	out, err := exec.Command("launchctl", "bootstrap", domain, plist).CombinedOutput()
	if err != nil {
		return fmt.Errorf("bootstrap 失败: %v / %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// stopLaunchAgent 卸载以真正停下（KeepAlive 下 stop 会被立刻拉起）。
func stopLaunchAgent(label string) error {
	domain := launchDomain()
	plist := launchAgentPlist(label)
	out, err := exec.Command("launchctl", "bootout", domain+"/"+label).CombinedOutput()
	if err != nil {
		out2, err2 := exec.Command("launchctl", "bootout", domain, plist).CombinedOutput()
		if err2 != nil {
			return fmt.Errorf("bootout 失败: %v / %s", err, strings.TrimSpace(string(out)+" "+string(out2)))
		}
	}
	return nil
}

// ---------- GUI Apps ----------

// listRunningApps 用 lsappinfo 列出前台 GUI 应用，并附上 RSS 内存。
func listRunningApps() []RunningApp {
	out, err := exec.Command("/usr/bin/lsappinfo", "list").CombinedOutput()
	if err != nil {
		return nil
	}
	apps := parseLSAppInfo(string(out))
	rss := processRSSBytes()
	for i := range apps {
		if apps[i].PID > 0 {
			apps[i].MemoryBytes = rss[apps[i].PID]
		}
	}
	return apps
}

// parseLSAppInfo 解析 lsappinfo list 输出。
// 只保留 Foreground；排除 Helper 与受保护的系统应用。
func parseLSAppInfo(raw string) []RunningApp {
	var apps []RunningApp
	var cur *RunningApp
	var appType string

	flush := func() {
		if cur == nil {
			return
		}
		if appType == "Foreground" &&
			!strings.Contains(cur.Name, "Helper") &&
			!isProtectedApp(cur.Name) {
			apps = append(apps, *cur)
		}
		cur = nil
		appType = ""
	}

	for _, line := range strings.Split(raw, "\n") {
		if m := reAppHeader.FindStringSubmatch(line); len(m) == 2 {
			flush()
			cur = &RunningApp{Name: m[1]}
			continue
		}
		if cur == nil {
			continue
		}
		if m := reBundleID.FindStringSubmatch(line); len(m) == 2 {
			cur.BundleID = m[1]
		}
		if m := reBundlePath.FindStringSubmatch(line); len(m) == 2 {
			cur.Path = m[1]
		}
		if m := rePIDType.FindStringSubmatch(line); len(m) == 3 {
			cur.PID, _ = strconv.Atoi(m[1])
			appType = m[2]
		}
	}
	flush()
	return apps
}

// listAvailableApps 扫描 /Applications 与 ~/Applications。
func listAvailableApps() []AvailableApp {
	dirs := []string{"/Applications", filepath.Join(homeDir(), "Applications")}
	seen := map[string]bool{}
	var out []AvailableApp
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			name := e.Name()
			if !strings.HasSuffix(name, ".app") {
				continue
			}
			display := strings.TrimSuffix(name, ".app")
			key := strings.ToLower(display)
			if seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, AvailableApp{
				Name: display,
				Path: filepath.Join(dir, name),
			})
		}
	}
	return out
}

// openApp 用 open -a 打开应用（名称须能被 Launch Services 解析）。
func openApp(name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("name 不能为空")
	}
	// 若给的是 .app 路径，限制在 Applications 下
	if strings.HasSuffix(strings.ToLower(name), ".app") || strings.Contains(name, "/") {
		clean, err := restrictAppPath(name)
		if err != nil {
			return err
		}
		out, err := exec.Command("open", clean).CombinedOutput()
		if err != nil {
			return fmt.Errorf("打开失败: %v / %s", err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	out, err := exec.Command("open", "-a", name).CombinedOutput()
	if err != nil {
		return fmt.Errorf("打开失败: %v / %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// openAppPath 按完整路径打开（供 API path 字段使用）。
func openAppPath(path string) error {
	clean, err := restrictAppPath(path)
	if err != nil {
		return err
	}
	out, err := exec.Command("open", clean).CombinedOutput()
	if err != nil {
		return fmt.Errorf("打开失败: %v / %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// quitApp 退出前台应用；系统关键应用拒绝关闭。
func quitApp(name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("name 不能为空")
	}
	if isProtectedApp(name) {
		return fmt.Errorf("系统关键应用不允许关闭: %s", name)
	}

	script := fmt.Sprintf(`tell application "%s" to quit`, escapeAppleScript(name))
	out, err := exec.Command("osascript", "-e", script).CombinedOutput()
	if err == nil {
		return nil
	}

	// 优雅退出失败：找 pid 再 SIGTERM
	pid := 0
	for _, a := range listRunningApps() {
		if strings.EqualFold(a.Name, name) {
			pid = a.PID
			break
		}
	}
	if pid <= 0 {
		return fmt.Errorf("退出失败: %v / %s", err, strings.TrimSpace(string(out)))
	}
	return killPID(name, pid)
}

// quitAppByPID 按 pid 关闭（须仍是可关闭的前台应用）。
func quitAppByPID(pid int) error {
	if pid <= 0 {
		return fmt.Errorf("pid 无效")
	}
	for _, a := range listRunningApps() {
		if a.PID == pid {
			if isProtectedApp(a.Name) {
				return fmt.Errorf("系统关键应用不允许关闭: %s", a.Name)
			}
			return quitApp(a.Name)
		}
	}
	return fmt.Errorf("进程 %d 不是可关闭的前台应用", pid)
}

func killPID(name string, pid int) error {
	if out, err := exec.Command("kill", "-TERM", strconv.Itoa(pid)).CombinedOutput(); err != nil {
		return fmt.Errorf("向 %s (%d) 发 SIGTERM 失败: %v / %s", name, pid, err, strings.TrimSpace(string(out)))
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if exec.Command("kill", "-0", strconv.Itoa(pid)).Run() != nil {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	_ = exec.Command("kill", "-KILL", strconv.Itoa(pid)).Run()
	return nil
}

// restrictAppPath 只允许打开 Applications 下的 .app。
func restrictAppPath(path string) (string, error) {
	clean := filepath.Clean(path)
	if !strings.HasSuffix(strings.ToLower(clean), ".app") {
		return "", fmt.Errorf("只能打开 .app: %s", clean)
	}
	abs, err := filepath.Abs(clean)
	if err != nil {
		return "", err
	}
	allowed := []string{
		"/Applications/",
		filepath.Join(homeDir(), "Applications") + "/",
	}
	for _, prefix := range allowed {
		if strings.HasPrefix(abs, prefix) {
			if st, err := os.Stat(abs); err != nil || !st.IsDir() {
				return "", fmt.Errorf("应用不存在: %s", abs)
			}
			return abs, nil
		}
	}
	return "", fmt.Errorf("路径不在允许的 Applications 目录内")
}

func escapeAppleScript(s string) string {
	return strings.ReplaceAll(s, `"`, `\"`)
}
