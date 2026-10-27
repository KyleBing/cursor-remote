# 变更日志

本项目所有值得注意的变更都记录在这里。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 新增

- **App 侧 markdown 渲染**：Agent 返回的正文不再按纯文本显示，改为解析后渲染——标题、有序/无序列表（含嵌套）、引用、分隔线、表格，以及行内粗体、斜体、行内代码与可点击链接。
- 代码块单独排版：等宽字体、横向滚动、语言标签和一键复制；流式输出中未闭合的围栏按「到文末」处理，不会把后半段文字吞成正文。
- 解析结果按文本内容缓存（最多 12 份），流式追加时已渲染块不再重复解析。

### 变更

- `server/server` 编译产物不再入库（`.gitignore` 补规则），避免 `go build` 每次都把 9 MB 二进制改成工作区改动。

## [1.0.0] - 2026-10-27

首个可用版本：从 Tailscale 内网方案切换到阿里云 VPS + frp 反向隧道，做到「公司 Mac 只出站、手机走公网 HTTPS」。

### 新增

- **服务端**（Go，仅标准库）：任务队列 + 事件落盘（可断点续传）、SSE 实时推送、项目白名单、Bearer token 鉴权、子进程生命周期管理。
- **iOS App**（SwiftUI，iOS 17+，iPhone / iPad 通用）：项目列表、任务创建、详情页流式输出、设置页；token 存 Keychain。
- **`relay/`**：`setup-aliyun.sh` 幂等安装 frps，并把 `/cursor-remote/` 注入现有 443 站点（复用 kylebing.cn 证书，不新增 DNS 记录）；附 `frpc.toml` / `frps.toml` / nginx 片段样例（token 为占位符）。
- **`scripts/install-frpc.sh`**：把 frpc 注册成 LaunchAgent，开机自启、断线自动重连。
- **`scripts/install-caffeinate.sh`**：接电源时阻止睡眠，避免隧道被系统休眠掐断。
- **`scripts/check-network.sh`**：只读网络诊断（控制面 / DERP / 出站连通性、MDM 管控、残留安装）。
- **`docs/architecture.md`**：链路各段职责、Cursor CLI 调用参数、流式与断点续传、headless 审批局限、网络选型取舍。

### 变更

- 跨网方案改为**阿里云 VPS 反向隧道**：服务端只监听 `127.0.0.1`，frp 隧道把 `8787` 映射到 VPS 回环，公网入口 `https://kylebing.cn/cursor-remote/`，TLS 由 nginx 终止。
- App 内置默认地址 `https://kylebing.cn/cursor-remote`，首次打开与退出登录后都不必手输。
- 事件不再推送 `raw` 字段（仅落盘用于复盘），实测流量降约 70%：单轮「重会话」传输约 107 KB，峰值 21 kbps。
- README 重写：网络选型对比与踩坑记录、阿里云部署步骤、带宽实测、已知限制。

### 修复

- 服务端未设置 `http.Server.Addr`，`-addr` 与配置里的 `port` 都不生效（会退回默认 80 端口）。
- App 把 query 直接拼进 path，`?` 被编码成 `%3F`，导致 `limit` 等查询参数丢失、接口返回异常。
- 服务端 LaunchAgent 未显式传 `-addr 127.0.0.1`，常驻进程仍监听全部网卡。
- `.gitignore` 补上仓库根目录的 `/bin/`（避免把误放的编译产物入库）。

### 已知限制

- headless 下无法远程逐条点「同意」，手机上只能选审批档位。
- 事件流里没有工具返回内容，命令输出需到 `~/.cursor/projects/<项目>/terminals/` 查看。
- Mac 合盖仍会睡眠，远程使用需保持开盖。

[1.0.0]: https://github.com/KyleBing/cursor-remote/releases/tag/v1.0.0
