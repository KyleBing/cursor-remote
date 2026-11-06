package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExpandShellCwd(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	got, err := expandShellCwd("")
	if err != nil || got != home {
		t.Fatalf("empty -> %q %v, want %q", got, err, home)
	}
	got, err = expandShellCwd("~")
	if err != nil || got != home {
		t.Fatalf("~ -> %q %v, want %q", got, err, home)
	}
	got, err = expandShellCwd("~/Developer")
	want := filepath.Join(home, "Developer")
	if err != nil || got != want {
		t.Fatalf("~/Developer -> %q %v, want %q", got, err, want)
	}
}

func TestExecShellEcho(t *testing.T) {
	res, err := execShell(ShellExecRequest{Command: "echo hello-shell", Cwd: "~", TimeoutSec: 10})
	if err != nil {
		t.Fatal(err)
	}
	if res.ExitCode != 0 || res.TimedOut {
		t.Fatalf("exit=%d timedOut=%v stderr=%q", res.ExitCode, res.TimedOut, res.Stderr)
	}
	if !strings.Contains(res.Stdout, "hello-shell") {
		t.Fatalf("stdout=%q", res.Stdout)
	}
}

func TestExecShellMissingCwd(t *testing.T) {
	_, err := execShell(ShellExecRequest{
		Command: "echo x",
		Cwd:     "/tmp/cursor-remote-no-such-dir-xyz",
	})
	if err == nil {
		t.Fatal("expected error for missing cwd")
	}
}
