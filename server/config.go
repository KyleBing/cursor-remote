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
	// 白名单项目只保留真实存在的目录。
	valid := cfg.Projects[:0]
	for _, pr := range cfg.Projects {
		if st, err := os.Stat(pr.Path); err == nil && st.IsDir() {
			valid = append(valid, pr)
		}
	}
	cfg.Projects = valid
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
