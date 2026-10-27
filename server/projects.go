package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// ProjectInfo 是返回给 App 的项目信息（含会话统计）。
type ProjectInfo struct {
	Name       string `json:"name"`
	Path       string `json:"path"`
	Sessions   int    `json:"sessions"`
	LastActive int64  `json:"lastActive"` // 毫秒时间戳，0 表示未知
}

// cliState 对应 ~/.cursor/agent-cli-state.json 的结构。
type cliState struct {
	WorkerIDsByDisplayName map[string]string `json:"workerIdsByDisplayName"`
}

// discoverProjects 从 Cursor CLI 的状态文件里推断出最近用过的项目。
// 键形如 "~/Developer/wubi/ios-wubi-manager (+6) @ Kyle's mbp"。
func discoverProjects() []Project {
	raw, err := os.ReadFile(filepath.Join(homeDir(), ".cursor", "agent-cli-state.json"))
	if err != nil {
		return nil
	}
	var st cliState
	if err := json.Unmarshal(raw, &st); err != nil {
		return nil
	}

	seen := map[string]bool{}
	var out []Project
	for key := range st.WorkerIDsByDisplayName {
		// 去掉 " (+N)" 与 " @ 机器名" 后缀。
		p := key
		if i := strings.Index(p, " ("); i > 0 {
			p = p[:i]
		}
		if i := strings.LastIndex(p, " @ "); i > 0 {
			p = p[:i]
		}
		p = strings.TrimSpace(p)
		if !strings.HasPrefix(p, "~") && !strings.HasPrefix(p, "/") {
			continue
		}
		abs := expandHome(p)
		if st, err := os.Stat(abs); err != nil || !st.IsDir() {
			continue
		}
		if seen[abs] {
			continue
		}
		seen[abs] = true
		out = append(out, Project{Name: filepath.Base(abs), Path: abs})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

// expandHome 把 ~ 展开为主目录。
func expandHome(p string) string {
	if p == "~" {
		return homeDir()
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(homeDir(), p[2:])
	}
	return p
}

// encodeProjectDir 把绝对路径编码成 ~/.cursor/projects 下的目录名。
// 例如 /Users/kyle/a/b -> Users-kyle-a-b。
func encodeProjectDir(path string) string {
	p := strings.TrimPrefix(filepath.Clean(path), "/")
	p = strings.ReplaceAll(p, "/", "-")
	return p
}

// statsCache 缓存项目统计，避免每次请求都扫目录。
type statsCache struct {
	mu      sync.Mutex
	at      time.Time
	entries map[string]ProjectInfo
}

var projectStats statsCache

// projectStatsFor 统计项目下的历史会话数与最近活跃时间。
func projectStatsFor(path string) (int, int64) {
	projectStats.mu.Lock()
	defer projectStats.mu.Unlock()

	if projectStats.entries == nil || time.Since(projectStats.at) > 30*time.Second {
		projectStats.entries = map[string]ProjectInfo{}
		projectStats.at = time.Now()
	}
	if v, ok := projectStats.entries[path]; ok {
		return v.Sessions, v.LastActive
	}

	dir := filepath.Join(homeDir(), ".cursor", "projects", encodeProjectDir(path), "agent-transcripts")
	info := ProjectInfo{Path: path}
	if ents, err := os.ReadDir(dir); err == nil {
		for _, e := range ents {
			if !e.IsDir() {
				continue
			}
			info.Sessions++
			// 用 jsonl 的修改时间近似最近活跃时间。
			if subs, err := os.ReadDir(filepath.Join(dir, e.Name())); err == nil {
				for _, s := range subs {
					if fi, err := s.Info(); err == nil {
						if ms := fi.ModTime().UnixMilli(); ms > info.LastActive {
							info.LastActive = ms
						}
					}
				}
			}
		}
	}
	projectStats.entries[path] = info
	return info.Sessions, info.LastActive
}
