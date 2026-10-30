package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	var (
		showToken    = flag.Bool("print-token", false, "只打印当前 token 后退出")
		syncProjects = flag.Bool("sync-projects", false, "从 Cursor CLI 状态合并项目到白名单后退出")
		addProject   = flag.String("add-project", "", "把指定目录加入白名单后退出（绝对路径或 ~/...）")
		port         = flag.Int("port", 0, "覆盖配置文件里的端口")
		addr         = flag.String("addr", "0.0.0.0", "监听地址")
	)
	flag.Parse()

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("加载配置失败: %v", err)
	}
	if *port > 0 {
		cfg.Port = *port
	}
	if *showToken {
		fmt.Println(cfg.Token)
		return
	}
	// 维护白名单：改完写盘即退出，运行中的服务需 kickstart 才会读到新配置；
	// 若服务已开，更推荐手机点「同步」或打 POST /api/projects/sync（热更新内存）。
	if *syncProjects {
		added, err := cfg.syncProjectsFromCLI()
		if err != nil {
			log.Fatalf("同步项目失败: %v", err)
		}
		fmt.Printf("新增 %d 个项目，白名单共 %d 个\n", len(added), len(cfg.Projects))
		for _, p := range added {
			fmt.Printf("  + %s  %s\n", p.Name, p.Path)
		}
		return
	}
	if *addProject != "" {
		proj, added, err := cfg.addProject("", *addProject)
		if err != nil {
			log.Fatalf("添加项目失败: %v", err)
		}
		if added {
			fmt.Printf("已添加: %s  %s\n", proj.Name, proj.Path)
		} else {
			fmt.Printf("已在白名单: %s  %s\n", proj.Name, proj.Path)
		}
		return
	}

	mgr, err := NewManager(cfg)
	if err != nil {
		log.Fatalf("恢复任务失败: %v", err)
	}

	srv := &http.Server{
		// 必须显式设置 Addr，否则 ListenAndServe 会退回默认的 :http（80 端口）
		Addr:              fmt.Sprintf("%s:%d", *addr, cfg.Port),
		Handler:           NewServer(cfg, mgr).Routes(),
		ReadHeaderTimeout: 10 * time.Second,
		// 不设 WriteTimeout：SSE 是长连接。
	}

	// 打印访问信息，方便在 iPad 上填。
	printBanner(cfg, *addr)

	// 优雅退出：收到信号后停掉所有在跑的任务。
	idle := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		log.Println("收到退出信号，正在关闭...")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
		close(idle)
	}()

	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("服务启动失败: %v", err)
	}
	<-idle
}

// printBanner 输出监听地址、Tailscale IP 与 token。
func printBanner(cfg *Config, addr string) {
	fmt.Println("─── cursor-remote ───")
	fmt.Printf("监听: %s:%d\n", addr, cfg.Port)
	if ips := tailscaleIPs(); len(ips) > 0 {
		for _, ip := range ips {
			fmt.Printf("Tailscale: http://%s:%d\n", ip, cfg.Port)
		}
	} else {
		fmt.Println("Tailscale: 未检测到（iPad 需与这台 Mac 在同一 tailnet）")
	}
	fmt.Printf("Agent: %s\n", orNone(cfg.AgentPath))
	fmt.Printf("项目: %d 个\n", len(cfg.Projects))
	fmt.Printf("Token: %s\n", cfg.Token)
	fmt.Println("把上面的地址和 token 填进 App 的设置页即可。")
	fmt.Println("─────────────────────")
}

// tailscaleIPs 取本机 Tailscale 地址，失败则返回空。
func tailscaleIPs() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []string
	for _, ifi := range ifaces {
		// Tailscale 的网卡名在 macOS 上通常是 utunN，用 CGNAT 段 100.64/10 判定更稳。
		addrs, err := ifi.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipn.IP.To4()
			if ip4 == nil {
				continue
			}
			if ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127 {
				out = append(out, ip4.String())
			}
		}
	}
	return out
}

// orNone 空值显示为 "未找到"。
func orNone(s string) string {
	if s == "" {
		return "未找到"
	}
	return s
}
