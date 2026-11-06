package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	shellDefaultTimeoutSec = 30
	shellMaxTimeoutSec     = 120
	// stdout+stderr 合计上限，超限截断并标记 truncated
	shellMaxOutputBytes = 200 * 1024
)

// ShellExecRequest 一次性命令执行请求。
type ShellExecRequest struct {
	Command    string `json:"command"`
	Cwd        string `json:"cwd"`
	TimeoutSec int    `json:"timeoutSec"`
}

// ShellExecResult 命令执行结果。
type ShellExecResult struct {
	Command    string `json:"command"`
	Cwd        string `json:"cwd"`
	ExitCode   int    `json:"exitCode"`
	Stdout     string `json:"stdout"`
	Stderr     string `json:"stderr"`
	DurationMs int64  `json:"durationMs"`
	TimedOut   bool   `json:"timedOut"`
	Truncated  bool   `json:"truncated"`
}

// expandShellCwd 空则用家目录；支持 ~/… 展开。
func expandShellCwd(raw string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	p := strings.TrimSpace(raw)
	if p == "" || p == "~" {
		return home, nil
	}
	if strings.HasPrefix(p, "~/") {
		p = filepath.Join(home, p[2:])
	}
	return filepath.Clean(p), nil
}

// execShell 用 zsh -lc 执行命令；超时杀进程组。
func execShell(req ShellExecRequest) (*ShellExecResult, error) {
	cmdText := strings.TrimSpace(req.Command)
	if cmdText == "" {
		return nil, errors.New("command 不能为空")
	}

	cwd, err := expandShellCwd(req.Cwd)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(cwd)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, errors.New("工作目录不存在: " + cwd)
		}
		return nil, err
	}
	if !info.IsDir() {
		return nil, errors.New("工作目录不是目录: " + cwd)
	}

	timeoutSec := req.TimeoutSec
	if timeoutSec <= 0 {
		timeoutSec = shellDefaultTimeoutSec
	}
	if timeoutSec > shellMaxTimeoutSec {
		timeoutSec = shellMaxTimeoutSec
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSec)*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "/bin/zsh", "-lc", cmdText)
	cmd.Dir = cwd
	// 独立进程组，超时后可一并杀掉子进程
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	var stdoutBuf, stderrBuf bytes.Buffer
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf

	started := time.Now()
	runErr := cmd.Run()
	durationMs := time.Since(started).Milliseconds()

	timedOut := false
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		timedOut = true
		// CommandContext 已发 SIGKILL；再兜底杀进程组
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
	}

	exitCode := 0
	if runErr != nil {
		var ee *exec.ExitError
		if errors.As(runErr, &ee) {
			exitCode = ee.ExitCode()
		} else if timedOut {
			exitCode = -1
		} else {
			return nil, runErr
		}
	}

	// stdout + stderr 合计不超过上限，优先保留 stdout
	stdoutRaw := stdoutBuf.Bytes()
	stderrRaw := stderrBuf.Bytes()
	truncated := false
	if len(stdoutRaw)+len(stderrRaw) > shellMaxOutputBytes {
		truncated = true
		if len(stdoutRaw) > shellMaxOutputBytes {
			stdoutRaw = stdoutRaw[:shellMaxOutputBytes]
			stderrRaw = nil
		} else {
			remain := shellMaxOutputBytes - len(stdoutRaw)
			if len(stderrRaw) > remain {
				stderrRaw = stderrRaw[:remain]
			}
		}
	}
	stdout := string(stdoutRaw)
	stderr := string(stderrRaw)
	if truncated {
		if len(stdoutRaw) == shellMaxOutputBytes {
			stdout += "\n…(已截断)"
		} else {
			stderr += "\n…(已截断)"
		}
	}

	return &ShellExecResult{
		Command:    cmdText,
		Cwd:        cwd,
		ExitCode:   exitCode,
		Stdout:     stdout,
		Stderr:     stderr,
		DurationMs: durationMs,
		TimedOut:   timedOut,
		Truncated:  truncated,
	}, nil
}
