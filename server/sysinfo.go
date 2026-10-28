package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------- 对外结构 ----------

// SystemInfo 是本机一揽子状态快照。
type SystemInfo struct {
	At        int64         `json:"at"` // 采集时间 unix ms
	Hardware  HardwareInfo  `json:"hardware"`
	Memory    MemoryInfo    `json:"memory"`
	Disks     []DiskInfo    `json:"disks"`
	Battery   BatteryInfo   `json:"battery"`
	Display   DisplayInfo   `json:"display"`
	Audio     AudioInfo     `json:"audio"`
	Network   NetworkInfo   `json:"network"`
	Bluetooth BluetoothInfo `json:"bluetooth"`
	LoadAvg   []float64     `json:"loadAvg"`
	UptimeSec int64         `json:"uptimeSec"`
}

// HardwareInfo 机型与芯片。
type HardwareInfo struct {
	ModelName       string `json:"modelName"`
	ModelIdentifier string `json:"modelIdentifier"`
	Chip            string `json:"chip"`
	Cores           string `json:"cores,omitempty"`
	MemoryGB        int    `json:"memoryGB"`
	SerialNumber    string `json:"serialNumber,omitempty"`
}

// MemoryInfo 物理内存与交换区。
type MemoryInfo struct {
	TotalBytes      int64   `json:"totalBytes"`
	UsedBytes       int64   `json:"usedBytes"`
	FreeBytes       int64   `json:"freeBytes"`
	WiredBytes      int64   `json:"wiredBytes"`
	CompressedBytes int64   `json:"compressedBytes"`
	AppBytes        int64   `json:"appBytes"` // active + inactive 近似
	SwapTotalBytes  int64   `json:"swapTotalBytes"`
	SwapUsedBytes   int64   `json:"swapUsedBytes"`
	Pressure        string  `json:"pressure,omitempty"` // normal / warn / critical
	UsedPercent     float64 `json:"usedPercent"`
}

// DiskInfo 一块挂载卷。
type DiskInfo struct {
	Mount       string  `json:"mount"`
	Device      string  `json:"device,omitempty"`
	TotalBytes  int64   `json:"totalBytes"`
	UsedBytes   int64   `json:"usedBytes"`
	FreeBytes   int64   `json:"freeBytes"`
	UsedPercent float64 `json:"usedPercent"`
}

// BatteryInfo 电池与电源。
type BatteryInfo struct {
	Percent     int    `json:"percent"`
	Charging    bool   `json:"charging"`
	ACPower     bool   `json:"acPower"`
	Present     bool   `json:"present"`
	TimeLeftMin int    `json:"timeLeftMin,omitempty"` // 估算剩余分钟，未知为 0
	Detail      string `json:"detail,omitempty"`
}

// DisplayInfo 屏幕亮度。
type DisplayInfo struct {
	Brightness    float64 `json:"brightness"`    // 0~1
	BrightnessPct int     `json:"brightnessPct"` // 0~100
	Nits          float64 `json:"nits,omitempty"`
	AutoBrightness bool   `json:"autoBrightness"`
}

// AudioInfo 系统音量。
type AudioInfo struct {
	OutputVolume int  `json:"outputVolume"` // 0~100
	InputVolume  int  `json:"inputVolume"`
	AlertVolume  int  `json:"alertVolume"`
	Muted        bool `json:"muted"`
}

// NetworkInfo 主网络与 Wi-Fi。
type NetworkInfo struct {
	PrimaryIF string   `json:"primaryInterface"`
	IPv4      string   `json:"ipv4,omitempty"`
	IPv6      string   `json:"ipv6,omitempty"`
	Gateway   string   `json:"gateway,omitempty"`
	DNS       []string `json:"dns,omitempty"`
	WiFi      *WiFiInfo `json:"wifi,omitempty"`
}

// WiFiInfo 当前无线连接摘要（SSID 在新系统上常被脱敏）。
type WiFiInfo struct {
	Connected   bool   `json:"connected"`
	SSID        string `json:"ssid,omitempty"`
	Channel     string `json:"channel,omitempty"`
	PHYMode     string `json:"phyMode,omitempty"`
	SignalDBm   string `json:"signalDBm,omitempty"`
	NoiseDBm    string `json:"noiseDBm,omitempty"`
	TransmitMbps string `json:"transmitMbps,omitempty"`
	Security    string `json:"security,omitempty"`
}

// BluetoothInfo 控制器与已配对设备。
type BluetoothInfo struct {
	On        bool              `json:"on"`
	Address   string            `json:"address,omitempty"`
	Connected []BluetoothDevice `json:"connected"`
	Paired    []BluetoothDevice `json:"paired"` // 未连接但已配对
}

// BluetoothDevice 蓝牙设备。
type BluetoothDevice struct {
	Name     string `json:"name"`
	Address  string `json:"address,omitempty"`
	Type     string `json:"type,omitempty"`
	Connected bool  `json:"connected"`
	Battery  string `json:"battery,omitempty"` // 如 "L100% R100% Case53%"
	RSSI     string `json:"rssi,omitempty"`
}

// ---------- 缓存 ----------

var (
	sysInfoMu   sync.Mutex
	sysInfoAt   time.Time
	sysInfoBody *SystemInfo
)

// invalidateSysInfoCache 调节亮度/音量后清缓存，下次拉取拿到新值。
func invalidateSysInfoCache() {
	sysInfoMu.Lock()
	sysInfoBody = nil
	sysInfoMu.Unlock()
}

// collectSystemInfo 采集本机状态；短时缓存避免频繁打 system_profiler。
func collectSystemInfo() SystemInfo {
	sysInfoMu.Lock()
	defer sysInfoMu.Unlock()
	if sysInfoBody != nil && time.Since(sysInfoAt) < 5*time.Second {
		return *sysInfoBody
	}
	info := SystemInfo{At: time.Now().UnixMilli()}
	info.Hardware = collectHardware()
	info.Memory = collectMemory()
	info.Disks = collectDisks()
	info.Battery = collectBattery()
	info.Display = collectDisplay()
	info.Audio = collectAudio()
	info.Network = collectNetwork()
	info.Bluetooth = collectBluetooth()
	info.LoadAvg = collectLoadAvg()
	info.UptimeSec = collectUptimeSec()
	sysInfoBody = &info
	sysInfoAt = time.Now()
	return info
}

// displayctlPath 定位同目录下的 displayctl.py（开发态 / 安装态都试一下）。
func displayctlPath() string {
	candidates := []string{
		filepath.Join(filepath.Dir(os.Args[0]), "displayctl.py"),
		filepath.Join(filepath.Dir(os.Args[0]), "..", "displayctl.py"),
	}
	// 源码树：server/bin/cursor-remote → server/displayctl.py
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(dir, "displayctl.py"),
			filepath.Join(dir, "..", "displayctl.py"),
		)
	}
	// 相对当前工作目录
	candidates = append(candidates, "displayctl.py", filepath.Join("server", "displayctl.py"))
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			abs, err := filepath.Abs(c)
			if err == nil {
				return abs
			}
			return c
		}
	}
	return ""
}

// setBrightnessPercent 设置内建屏亮度，percent 为 0~100。
func setBrightnessPercent(percent int) (DisplayInfo, error) {
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	script := displayctlPath()
	if script == "" {
		return DisplayInfo{}, fmt.Errorf("找不到 displayctl.py")
	}
	level := float64(percent) / 100
	out, err := exec.Command("python3", script, "set", fmt.Sprintf("%.4f", level)).CombinedOutput()
	if err != nil {
		return DisplayInfo{}, fmt.Errorf("设置亮度失败: %v / %s", err, strings.TrimSpace(string(out)))
	}
	invalidateSysInfoCache()
	d := collectDisplay()
	// collectDisplay 走 corebrightnessdiag，可能稍滞后；用脚本回读兜底
	if d.BrightnessPct == 0 && percent > 0 {
		if got, err := exec.Command("python3", script, "get").CombinedOutput(); err == nil {
			if v, err := strconv.ParseFloat(strings.TrimSpace(string(got)), 64); err == nil {
				d.Brightness = v
				d.BrightnessPct = int(mathRound(v * 100))
			}
		}
	}
	return d, nil
}

// setVolume 设置输出音量（0~100）与静音；muted 为 nil 表示不改静音。
func setVolume(percent int, muted *bool) (AudioInfo, error) {
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	script := fmt.Sprintf("set volume output volume %d", percent)
	if muted != nil {
		if *muted {
			script += " with output muted"
		} else {
			script += " without output muted"
		}
	}
	out, err := exec.Command("osascript", "-e", script).CombinedOutput()
	if err != nil {
		return AudioInfo{}, fmt.Errorf("设置音量失败: %v / %s", err, strings.TrimSpace(string(out)))
	}
	invalidateSysInfoCache()
	return collectAudio(), nil
}

// ---------- 进程内存 ----------

// processRSSBytes 返回 pid -> RSS 字节（来自 ps rss，单位 KB）。
func processRSSBytes() map[int]int64 {
	out, err := exec.Command("ps", "-axo", "pid=,rss=").Output()
	if err != nil {
		return nil
	}
	m := make(map[int]int64, 256)
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 2 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		rssKB, err2 := strconv.ParseInt(fields[1], 10, 64)
		if err1 != nil || err2 != nil || pid <= 0 {
			continue
		}
		m[pid] = rssKB * 1024
	}
	return m
}

// ---------- 采集实现 ----------

func collectHardware() HardwareInfo {
	h := HardwareInfo{}
	if v, err := exec.Command("sysctl", "-n", "hw.model").Output(); err == nil {
		h.ModelIdentifier = strings.TrimSpace(string(v))
	}
	if v, err := exec.Command("sysctl", "-n", "hw.memsize").Output(); err == nil {
		if n, err := strconv.ParseInt(strings.TrimSpace(string(v)), 10, 64); err == nil {
			h.MemoryGB = int(n / (1024 * 1024 * 1024))
		}
	}
	if v, err := exec.Command("sysctl", "-n", "machdep.cpu.brand_string").Output(); err == nil {
		h.Chip = strings.TrimSpace(string(v))
	}
	// 型号名 / 核心 / 序列号来自 system_profiler（文本解析足够）
	out, err := exec.Command("system_profiler", "SPHardwareDataType").Output()
	if err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			line = strings.TrimSpace(line)
			switch {
			case strings.HasPrefix(line, "Model Name:"):
				h.ModelName = strings.TrimSpace(strings.TrimPrefix(line, "Model Name:"))
			case strings.HasPrefix(line, "Model Identifier:"):
				h.ModelIdentifier = strings.TrimSpace(strings.TrimPrefix(line, "Model Identifier:"))
			case strings.HasPrefix(line, "Chip:"):
				h.Chip = strings.TrimSpace(strings.TrimPrefix(line, "Chip:"))
			case strings.HasPrefix(line, "Total Number of Cores:"):
				h.Cores = strings.TrimSpace(strings.TrimPrefix(line, "Total Number of Cores:"))
			case strings.HasPrefix(line, "Serial Number (system):"):
				h.SerialNumber = strings.TrimSpace(strings.TrimPrefix(line, "Serial Number (system):"))
			}
		}
	}
	if h.ModelName == "" {
		h.ModelName = "Mac"
	}
	return h
}

var reVMStat = regexp.MustCompile(`^Pages\s+([^:]+):\s+(\d+)`)

func collectMemory() MemoryInfo {
	m := MemoryInfo{}
	pageSize := int64(16384)
	if v, err := exec.Command("pagesize").Output(); err == nil {
		if n, err := strconv.ParseInt(strings.TrimSpace(string(v)), 10, 64); err == nil && n > 0 {
			pageSize = n
		}
	}
	if v, err := exec.Command("sysctl", "-n", "hw.memsize").Output(); err == nil {
		m.TotalBytes, _ = strconv.ParseInt(strings.TrimSpace(string(v)), 10, 64)
	}

	pages := map[string]int64{}
	if out, err := exec.Command("vm_stat").Output(); err == nil {
		sc := bufio.NewScanner(strings.NewReader(string(out)))
		for sc.Scan() {
			line := sc.Text()
			if mm := reVMStat.FindStringSubmatch(line); len(mm) == 3 {
				key := strings.TrimSpace(mm[1])
				n, _ := strconv.ParseInt(strings.TrimSuffix(mm[2], "."), 10, 64)
				pages[key] = n
			}
			// "Pages occupied by compressor:" 单独匹配
			if strings.HasPrefix(line, "Pages occupied by compressor:") {
				n, _ := strconv.ParseInt(strings.TrimSuffix(strings.TrimSpace(strings.TrimPrefix(line, "Pages occupied by compressor:")), "."), 10, 64)
				pages["occupied by compressor"] = n
			}
		}
	}
	free := (pages["free"] + pages["speculative"]) * pageSize
	wired := pages["wired down"] * pageSize
	compressed := pages["occupied by compressor"] * pageSize
	active := pages["active"] * pageSize
	inactive := pages["inactive"] * pageSize
	m.FreeBytes = free
	m.WiredBytes = wired
	m.CompressedBytes = compressed
	m.AppBytes = active + inactive
	// 已用 ≈ 总量 - 空闲（与活动监视器「已使用内存」更接近）
	if m.TotalBytes > 0 {
		m.UsedBytes = m.TotalBytes - free
		if m.UsedBytes < 0 {
			m.UsedBytes = 0
		}
		m.UsedPercent = float64(m.UsedBytes) * 100 / float64(m.TotalBytes)
	}

	// swap：vm.swapusage → "total = 5120.00M  used = 4343.62M  free = 776.38M"
	if out, err := exec.Command("sysctl", "-n", "vm.swapusage").Output(); err == nil {
		txt := string(out)
		if mm := regexp.MustCompile(`total\s*=\s*([\d.]+)([MG])`).FindStringSubmatch(txt); len(mm) == 3 {
			m.SwapTotalBytes = parseSizeMG(mm[1], mm[2])
		}
		if mm := regexp.MustCompile(`used\s*=\s*([\d.]+)([MG])`).FindStringSubmatch(txt); len(mm) == 3 {
			m.SwapUsedBytes = parseSizeMG(mm[1], mm[2])
		}
	}

	// 内存压力：memory_pressure 最后一行常含 "System-wide memory free percentage: N %"
	if out, err := exec.Command("memory_pressure").CombinedOutput(); err == nil {
		txt := string(out)
		switch {
		case strings.Contains(txt, "critical"):
			m.Pressure = "critical"
		case strings.Contains(txt, "warn"):
			m.Pressure = "warn"
		default:
			m.Pressure = "normal"
		}
	}
	return m
}

func parseSizeMG(num, unit string) int64 {
	f, _ := strconv.ParseFloat(num, 64)
	switch unit {
	case "G":
		return int64(f * 1024 * 1024 * 1024)
	default: // M
		return int64(f * 1024 * 1024)
	}
}

func collectDisks() []DiskInfo {
	// -k 以 1024 字节块计；只要本机 APFS 数据卷与根
	out, err := exec.Command("df", "-k").Output()
	if err != nil {
		return nil
	}
	var disks []DiskInfo
	seen := map[string]bool{}
	sc := bufio.NewScanner(strings.NewReader(string(out)))
	sc.Scan() // header
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 9 {
			continue
		}
		mount := fields[len(fields)-1]
		// 只保留用户关心的卷：/ 与 /System/Volumes/Data
		if mount != "/" && mount != "/System/Volumes/Data" {
			continue
		}
		totalK, _ := strconv.ParseInt(fields[1], 10, 64)
		usedK, _ := strconv.ParseInt(fields[2], 10, 64)
		availK, _ := strconv.ParseInt(fields[3], 10, 64)
		key := fields[0]
		if seen[key] && mount == "/" {
			continue
		}
		seen[key+mount] = true
		d := DiskInfo{
			Mount:      mount,
			Device:     fields[0],
			TotalBytes: totalK * 1024,
			UsedBytes:  usedK * 1024,
			FreeBytes:  availK * 1024,
		}
		if d.TotalBytes > 0 {
			d.UsedPercent = float64(d.UsedBytes) * 100 / float64(d.TotalBytes)
		}
		// Data 卷对用户更有意义，标一下
		if mount == "/System/Volumes/Data" {
			d.Mount = "Macintosh HD · Data"
		} else if mount == "/" {
			d.Mount = "Macintosh HD · System"
		}
		disks = append(disks, d)
	}
	return disks
}

var (
	reBattPercent = regexp.MustCompile(`(\d+)%`)
	reBattTime    = regexp.MustCompile(`(\d+:\d+)\s+remaining`)
)

func collectBattery() BatteryInfo {
	b := BatteryInfo{Present: true}
	out, err := exec.Command("pmset", "-g", "batt").CombinedOutput()
	if err != nil {
		b.Present = false
		b.Detail = "无法读取电池"
		return b
	}
	txt := string(out)
	b.ACPower = strings.Contains(txt, "AC Power") || strings.Contains(txt, "AC attached")
	b.Charging = strings.Contains(strings.ToLower(txt), "charging") && !strings.Contains(txt, "not charging")
	if mm := reBattPercent.FindStringSubmatch(txt); len(mm) == 2 {
		b.Percent, _ = strconv.Atoi(mm[1])
	}
	if !strings.Contains(txt, "InternalBattery") {
		b.Present = false
	}
	// "2:15 remaining"
	if mm := reBattTime.FindStringSubmatch(txt); len(mm) == 2 {
		parts := strings.Split(mm[1], ":")
		if len(parts) == 2 {
			h, _ := strconv.Atoi(parts[0])
			m, _ := strconv.Atoi(parts[1])
			b.TimeLeftMin = h*60 + m
		}
	}
	lines := strings.Split(strings.TrimSpace(txt), "\n")
	if len(lines) > 0 {
		b.Detail = strings.TrimSpace(lines[0])
	}
	return b
}

func collectDisplay() DisplayInfo {
	d := DisplayInfo{}
	out, err := exec.Command("/usr/libexec/corebrightnessdiag", "status-info").CombinedOutput()
	if err != nil {
		return d
	}
	txt := string(out)
	if mm := regexp.MustCompile(`<key>DisplayServicesBrightness</key>\s*<real>([0-9.]+)</real>`).FindStringSubmatch(txt); len(mm) == 2 {
		d.Brightness, _ = strconv.ParseFloat(mm[1], 64)
	} else if mm := regexp.MustCompile(`DisplayServicesBrightness\s*=\s*"?([0-9.]+)`).FindStringSubmatch(txt); len(mm) == 2 {
		d.Brightness, _ = strconv.ParseFloat(mm[1], 64)
	}
	if d.Brightness > 1 {
		d.Brightness = 1
	}
	if d.Brightness < 0 {
		d.Brightness = 0
	}
	d.BrightnessPct = int(mathRound(d.Brightness * 100))
	if mm := regexp.MustCompile(`<key>DisplayNitsKey</key>\s*<real>([0-9.]+)</real>`).FindStringSubmatch(txt); len(mm) == 2 {
		d.Nits, _ = strconv.ParseFloat(mm[1], 64)
	}
	if strings.Contains(txt, "<key>CBAutoBrightnessEnabled</key>") {
		d.AutoBrightness = strings.Contains(txt, "<key>CBAutoBrightnessEnabled</key>\n\t\t\t\t<true/>") ||
			strings.Contains(txt, "CBAutoBrightnessEnabled = 1") ||
			strings.Contains(txt, "DisplayBrightnessAuto = 1")
	}
	return d
}

func mathRound(v float64) float64 {
	return float64(int(v + 0.5))
}

func collectAudio() AudioInfo {
	a := AudioInfo{}
	out, err := exec.Command("osascript", "-e", "get volume settings").CombinedOutput()
	if err != nil {
		return a
	}
	// output volume:0, input volume:63, alert volume:100, output muted:true
	txt := string(out)
	if mm := regexp.MustCompile(`output volume:(\d+)`).FindStringSubmatch(txt); len(mm) == 2 {
		a.OutputVolume, _ = strconv.Atoi(mm[1])
	}
	if mm := regexp.MustCompile(`input volume:(\d+)`).FindStringSubmatch(txt); len(mm) == 2 {
		a.InputVolume, _ = strconv.Atoi(mm[1])
	}
	if mm := regexp.MustCompile(`alert volume:(\d+)`).FindStringSubmatch(txt); len(mm) == 2 {
		a.AlertVolume, _ = strconv.Atoi(mm[1])
	}
	a.Muted = strings.Contains(txt, "output muted:true")
	return a
}

func collectNetwork() NetworkInfo {
	n := NetworkInfo{}
	// 主接口 + 网关
	if out, err := exec.Command("route", "-n", "get", "default").Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "interface:") {
				n.PrimaryIF = strings.TrimSpace(strings.TrimPrefix(line, "interface:"))
			}
			if strings.HasPrefix(line, "gateway:") {
				n.Gateway = strings.TrimSpace(strings.TrimPrefix(line, "gateway:"))
			}
		}
	}
	if n.PrimaryIF == "" {
		n.PrimaryIF = "en0"
	}
	// IPv4 / IPv6
	if out, err := exec.Command("ipconfig", "getifaddr", n.PrimaryIF).Output(); err == nil {
		n.IPv4 = strings.TrimSpace(string(out))
	}
	if out, err := exec.Command("ifconfig", n.PrimaryIF).Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "inet6 ") && !strings.Contains(line, "fe80:") && !strings.Contains(line, "scopeid") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					n.IPv6 = fields[1]
					break
				}
			}
			if n.IPv6 == "" && strings.HasPrefix(line, "inet6 ") {
				fields := strings.Fields(line)
				if len(fields) >= 2 && !strings.HasPrefix(fields[1], "fe80") {
					n.IPv6 = fields[1]
				}
			}
		}
	}
	// DNS
	if out, err := exec.Command("scutil", "--dns").Output(); err == nil {
		seen := map[string]bool{}
		sc := bufio.NewScanner(strings.NewReader(string(out)))
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if strings.HasPrefix(line, "nameserver[") {
				parts := strings.SplitN(line, ":", 2)
				if len(parts) == 2 {
					ip := strings.TrimSpace(parts[1])
					if ip != "" && !seen[ip] {
						seen[ip] = true
						n.DNS = append(n.DNS, ip)
						if len(n.DNS) >= 3 {
							break
						}
					}
				}
			}
		}
	}
	n.WiFi = collectWiFi()
	return n
}

func collectWiFi() *WiFiInfo {
	out, err := exec.Command("system_profiler", "SPAirPortDataType").Output()
	if err != nil {
		return nil
	}
	txt := string(out)
	w := &WiFiInfo{}
	// Status: Connected
	w.Connected = strings.Contains(txt, "Status: Connected")
	if !w.Connected {
		return w
	}
	// 在 Current Network Information 段里抠字段
	idx := strings.Index(txt, "Current Network Information:")
	section := txt
	if idx >= 0 {
		section = txt[idx:]
		if end := strings.Index(section, "Other Local Wi-Fi Networks:"); end > 0 {
			section = section[:end]
		}
	}
	for _, line := range strings.Split(section, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "PHY Mode:"):
			w.PHYMode = strings.TrimSpace(strings.TrimPrefix(line, "PHY Mode:"))
		case strings.HasPrefix(line, "Channel:"):
			w.Channel = strings.TrimSpace(strings.TrimPrefix(line, "Channel:"))
		case strings.HasPrefix(line, "Security:"):
			w.Security = strings.TrimSpace(strings.TrimPrefix(line, "Security:"))
		case strings.HasPrefix(line, "Signal / Noise:"):
			rest := strings.TrimSpace(strings.TrimPrefix(line, "Signal / Noise:"))
			parts := strings.Split(rest, "/")
			if len(parts) >= 1 {
				w.SignalDBm = strings.TrimSpace(parts[0])
			}
			if len(parts) >= 2 {
				w.NoiseDBm = strings.TrimSpace(parts[1])
			}
		case strings.HasPrefix(line, "Transmit Rate:"):
			w.TransmitMbps = strings.TrimSpace(strings.TrimPrefix(line, "Transmit Rate:"))
		}
	}
	// SSID：新系统常脱敏；若行形如 "MySSID:" 且缩进较深可尝试
	return w
}

func collectBluetooth() BluetoothInfo {
	b := BluetoothInfo{Connected: []BluetoothDevice{}, Paired: []BluetoothDevice{}}
	out, err := exec.Command("system_profiler", "SPBluetoothDataType").Output()
	if err != nil {
		return b
	}
	lines := strings.Split(string(out), "\n")
	section := "" // controller | connected | not_connected
	var cur *BluetoothDevice
	flush := func() {
		if cur == nil {
			return
		}
		if cur.Connected {
			b.Connected = append(b.Connected, *cur)
		} else {
			b.Paired = append(b.Paired, *cur)
		}
		cur = nil
	}
	for _, raw := range lines {
		line := strings.TrimRight(raw, "\r")
		trim := strings.TrimSpace(line)
		indent := len(line) - len(strings.TrimLeft(line, " "))

		switch {
		case strings.HasPrefix(trim, "State:"):
			b.On = strings.Contains(trim, "On")
		case strings.HasPrefix(trim, "Address:") && section == "controller":
			b.Address = strings.TrimSpace(strings.TrimPrefix(trim, "Address:"))
		case trim == "Bluetooth Controller:":
			flush()
			section = "controller"
		case trim == "Connected:":
			flush()
			section = "connected"
		case trim == "Not Connected:":
			flush()
			section = "not_connected"
		case (section == "connected" || section == "not_connected") && indent == 10 && strings.HasSuffix(trim, ":"):
			// 设备名行： "Kyle's Mouse:"
			flush()
			name := strings.TrimSuffix(trim, ":")
			cur = &BluetoothDevice{Name: name, Connected: section == "connected"}
		case cur != nil && strings.Contains(trim, ":"):
			key, val, ok := strings.Cut(trim, ":")
			if !ok {
				continue
			}
			key, val = strings.TrimSpace(key), strings.TrimSpace(val)
			switch key {
			case "Address":
				cur.Address = val
			case "Minor Type":
				cur.Type = val
			case "RSSI":
				cur.RSSI = val
			case "Case Battery Level":
				cur.Battery = joinBattery(cur.Battery, "Case"+val)
			case "Left Battery Level":
				cur.Battery = joinBattery(cur.Battery, "L"+val)
			case "Right Battery Level":
				cur.Battery = joinBattery(cur.Battery, "R"+val)
			case "Battery Level":
				cur.Battery = joinBattery(cur.Battery, val)
			}
		}
	}
	flush()
	return b
}

func joinBattery(existing, part string) string {
	if existing == "" {
		return part
	}
	return existing + " " + part
}

func collectLoadAvg() []float64 {
	out, err := exec.Command("sysctl", "-n", "vm.loadavg").Output()
	if err != nil {
		return nil
	}
	// { 3.48 3.87 4.86 }
	txt := strings.Trim(strings.TrimSpace(string(out)), "{}")
	parts := strings.Fields(txt)
	var outf []float64
	for _, p := range parts {
		if f, err := strconv.ParseFloat(p, 64); err == nil {
			outf = append(outf, f)
		}
	}
	return outf
}

func collectUptimeSec() int64 {
	// sysctl kern.boottime → { sec = 1792888636, usec = 14739 }
	out, err := exec.Command("sysctl", "-n", "kern.boottime").Output()
	if err != nil {
		return 0
	}
	mm := regexp.MustCompile(`sec\s*=\s*(\d+)`).FindStringSubmatch(string(out))
	if len(mm) != 2 {
		return 0
	}
	sec, _ := strconv.ParseInt(mm[1], 10, 64)
	if sec <= 0 {
		return 0
	}
	return time.Now().Unix() - sec
}

// formatBytes 给人看的容量（供测试 / 调试）。
func formatBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for v := n / unit; v >= unit; v /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}
