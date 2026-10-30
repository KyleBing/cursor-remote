package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// Project 是一个可以被远程发起对话的项目（白名单）。
type Project struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// Config 服务端配置，落在 ~/.cursor-remote/config.json。
type Config struct {
	Port            int       `json:"port"`
	Token           string    `json:"token"`
	AgentPath       string    `json:"agentPath"`
	Projects        []Project `json:"projects"`
	Programs        []Program `json:"programs"`        // 可远程启停的本机程序白名单
	DefaultApproval string    `json:"defaultApproval"` // default | auto-review | force
	DefaultModel    string    `json:"defaultModel"`
	AllowForce      bool      `json:"allowForce"`
	ExtraArgs       []string  `json:"extraArgs"`
	AllowedModels   []string  `json:"allowedModels"`

	// path 为配置文件自身位置，不参与序列化。
	path string
}

// homeDir 返回当前用户主目录。
func homeDir() string {
	h, err := os.UserHomeDir()
	if err != nil {
		return "/tmp"
	}
	return h
}

// dataDir 返回服务端数据目录 ~/.cursor-remote。
func dataDir() string {
	return filepath.Join(homeDir(), ".cursor-remote")
}

// tasksDir 返回任务落盘目录。
func tasksDir() string {
	return filepath.Join(dataDir(), "tasks")
}

// ensureDirs 创建运行所需目录。
func ensureDirs() error {
	for _, d := range []string{dataDir(), tasksDir()} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return err
		}
	}
	return nil
}

// findAgentCLI 依次探测常见的 agent 可执行文件位置。
func findAgentCLI() string {
	candidates := []string{
		filepath.Join(homeDir(), ".local/bin/agent"),
		filepath.Join(homeDir(), ".local/bin/cursor-agent"),
		"/opt/homebrew/bin/agent",
		"/usr/local/bin/agent",
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c
		}
	}
	// 兜底交给 PATH 解析。
	if p, err := exec.LookPath("agent"); err == nil {
		return p
	}
	if p, err := exec.LookPath("cursor-agent"); err == nil {
		return p
	}
	return ""
}

// newToken 生成 32 字节随机 token，用于 Bearer 鉴权。
func newToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "insecure-fallback-token"
	}
	return hex.EncodeToString(b)
}

// loadConfig 读取配置；不存在时生成一份带随机 token 的默认配置并落盘。
func loadConfig() (*Config, error) {
	if err := ensureDirs(); err != nil {
		return nil, err
	}
	p := filepath.Join(dataDir(), "config.json")
	raw, err := os.ReadFile(p)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		cfg := &Config{
			Port:            8787,
			Token:           newToken(),
			AgentPath:       findAgentCLI(),
			Projects:        discoverProjects(),
			Programs:        defaultPrograms(),
			DefaultApproval: "auto-review",
			DefaultModel:    "",
			AllowForce:      false,
			AllowedModels:   []string{"auto", "composer-2.5"},
			path:            p,
		}
		return cfg, cfg.save()
	}

	var cfg Config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("解析 %s 失败: %w", p, err)
	}
	cfg.path = p
	if cfg.Port == 0 {
		cfg.Port = 8787
	}
	if cfg.Token == "" {
		cfg.Token = newToken()
	}
	if cfg.AgentPath == "" {
		cfg.AgentPath = findAgentCLI()
	}
	if cfg.DefaultApproval == "" {
		cfg.DefaultApproval = "auto-review"
	}
	if len(cfg.AllowedModels) == 0 {
		cfg.AllowedModels = []string{"auto"}
	}
	// programs 字段缺失时用默认受管列表并写回；显式写成 [] 则保持为空。
	seedPrograms := cfg.Programs == nil
	if seedPrograms {
		cfg.Programs = defaultPrograms()
	}
	// 白名单项目只保留真实存在的目录。
	valid := cfg.Projects[:0]
	for _, pr := range cfg.Projects {
		if st, err := os.Stat(pr.Path); err == nil && st.IsDir() {
			valid = append(valid, pr)
		}
	}
	cfg.Projects = valid
	if seedPrograms {
		_ = cfg.save()
	}
	return &cfg, nil
}

// save 原子写回配置文件。
func (c *Config) save() error {
	if c.path == "" {
		c.path = filepath.Join(dataDir(), "config.json")
	}
	raw, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, append(raw, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}

// projectByPath 按路径查白名单项目，防止任意路径执行。
func (c *Config) projectByPath(path string) (Project, bool) {
	clean := filepath.Clean(path)
	for _, p := range c.Projects {
		if filepath.Clean(p.Path) == clean {
			return p, true
		}
	}
	return Project{}, false
}

// projectByName 按名称查白名单项目。
func (c *Config) projectByName(name string) (Project, bool) {
	for _, p := range c.Projects {
		if p.Name == name {
			return p, true
		}
	}
	return Project{}, false
}

// ensureUniqueName 避免白名单里出现同名不同路径。
func (c *Config) ensureUniqueName(name, path string) string {
	clean := filepath.Clean(path)
	if p, ok := c.projectByName(name); !ok || filepath.Clean(p.Path) == clean {
		return name
	}
	parent := filepath.Base(filepath.Dir(clean))
	if parent != "" && parent != "." && parent != "/" {
		cand := parent + "-" + name
		if p, ok := c.projectByName(cand); !ok || filepath.Clean(p.Path) == clean {
			return cand
		}
	}
	for i := 2; ; i++ {
		cand := fmt.Sprintf("%s-%d", name, i)
		if _, ok := c.projectByName(cand); !ok {
			return cand
		}
	}
}

// addProject 把目录加入白名单并落盘；已存在时返回已有项且 added=false。
func (c *Config) addProject(name, path string) (Project, bool, error) {
	abs := expandHome(strings.TrimSpace(path))
	abs, err := filepath.Abs(abs)
	if err != nil {
		return Project{}, false, fmt.Errorf("解析路径失败: %w", err)
	}
	st, err := os.Stat(abs)
	if err != nil || !st.IsDir() {
		return Project{}, false, fmt.Errorf("目录不存在: %s", abs)
	}
	if existing, ok := c.projectByPath(abs); ok {
		return existing, false, nil
	}
	if strings.TrimSpace(name) == "" {
		name = filepath.Base(abs)
	}
	p := Project{Name: c.ensureUniqueName(name, abs), Path: abs}
	c.Projects = append(c.Projects, p)
	sort.Slice(c.Projects, func(i, j int) bool { return c.Projects[i].Path < c.Projects[j].Path })
	if err := c.save(); err != nil {
		return Project{}, false, err
	}
	return p, true, nil
}

// removeProject 按名称或路径从白名单移除并落盘。
func (c *Config) removeProject(key string) (Project, bool, error) {
	key = strings.TrimSpace(key)
	if key == "" {
		return Project{}, false, fmt.Errorf("缺少项目名或路径")
	}
	idx := -1
	var removed Project
	for i, p := range c.Projects {
		if p.Name == key || filepath.Clean(p.Path) == filepath.Clean(expandHome(key)) {
			idx = i
			removed = p
			break
		}
	}
	if idx < 0 {
		return Project{}, false, nil
	}
	c.Projects = append(c.Projects[:idx], c.Projects[idx+1:]...)
	if err := c.save(); err != nil {
		return Project{}, false, err
	}
	return removed, true, nil
}

// syncProjectsFromCLI 把 Cursor CLI 状态里出现过的目录合并进白名单。
func (c *Config) syncProjectsFromCLI() (added []Project, err error) {
	for _, p := range discoverProjects() {
		if _, ok := c.projectByPath(p.Path); ok {
			continue
		}
		proj := Project{Name: c.ensureUniqueName(p.Name, p.Path), Path: p.Path}
		c.Projects = append(c.Projects, proj)
		added = append(added, proj)
	}
	if len(added) == 0 {
		return nil, nil
	}
	sort.Slice(c.Projects, func(i, j int) bool { return c.Projects[i].Path < c.Projects[j].Path })
	if err := c.save(); err != nil {
		return nil, err
	}
	return added, nil
}

// normalizeApproval 把请求里的审批模式收敛到合法值。
func (c *Config) normalizeApproval(v string) string {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "force", "yolo":
		// 未显式允许时降级为 auto-review，避免手机上一键全放开。
		if !c.AllowForce {
			return "auto-review"
		}
		return "force"
	case "default", "ask":
		return "default"
	default:
		return "auto-review"
	}
}
