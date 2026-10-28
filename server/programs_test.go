package main

import (
	"strings"
	"testing"
)

func TestParseLSAppInfo(t *testing.T) {
	raw := `
 7) "Finder" ASN:0x0-0x12012: 
    bundleID="com.apple.finder"
    bundle path="/System/Library/CoreServices/Finder.app"
    pid = 748 token=[sess=100022 pid=748] type="Foreground" flavor=3 Version="1865"
101) "Cursor" ASN:0x0-0x619619: 
    bundleID="com.todesktop.230313mzl4w4u92"
    bundle path="/Applications/Cursor.app"
    pid = 9814 token=[sess=100022 pid=9814] type="Foreground" flavor=3 Version="3.27.22"
102) "Cursor Helper: shared-process" ASN:0x0-0x61a61a: 
    bundleID="com.todesktop.230313mzl4w4u92.helper"
    bundle path="/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app"
    pid = 9833 token=[sess=100022 pid=9833] type="Foreground" flavor=3 Version="3.27.22"
 3) "universalaccessd" ASN:0x0-0xb00b: 
    bundleID=[ NULL ] 
    pid = 717 token=[sess=100022 pid=717] type="BackgroundOnly" flavor=3
`
	apps := parseLSAppInfo(raw)
	// Finder 受保护不返回；Helper / Background 也不返回
	if len(apps) != 1 {
		t.Fatalf("期望 1 个前台应用，实际 %d: %+v", len(apps), apps)
	}
	if apps[0].Name != "Cursor" || apps[0].PID != 9814 || apps[0].BundleID == "" {
		t.Fatalf("Cursor 解析错误: %+v", apps[0])
	}
}

func TestIsProtectedApp(t *testing.T) {
	if !isProtectedApp("Finder") || !isProtectedApp("Dock") {
		t.Fatal("系统应用应受保护")
	}
	if isProtectedApp("Cursor") || isProtectedApp("Safari") {
		t.Fatal("普通应用不应受保护")
	}
}

func TestProgramsAPI(t *testing.T) {
	s, cfg, _ := newTestServer(t)
	cfg.Programs = []Program{
		{ID: "demo-app", Name: "不存在的应用", Kind: "app", AppName: "DefinitelyNotAnAppXYZ"},
	}

	w := doReq(t, s, "GET", "/api/programs", "")
	if w.Code != 200 {
		t.Fatalf("list programs: %d %s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	if !strings.Contains(body, `"programs"`) || !strings.Contains(body, `"demo-app"`) {
		t.Fatalf("响应缺少字段: %s", body)
	}

	w = doReq(t, s, "GET", "/api/apps", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"apps"`) {
		t.Fatalf("list apps: %d %s", w.Code, w.Body.String())
	}

	w = doReq(t, s, "POST", "/api/programs/missing/start", "")
	if w.Code != 404 {
		t.Fatalf("未知 id 应 404，实际 %d", w.Code)
	}

	w = doReq(t, s, "POST", "/api/apps/open", `{}`)
	if w.Code != 400 {
		t.Fatalf("空 name/path 应 400，实际 %d", w.Code)
	}
}
