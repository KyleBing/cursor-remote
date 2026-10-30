# 变更日志

本项目所有值得注意的变更都记录在这里。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 变更

- **任务详情精简**：不再展开具体工具步骤（读文件 / 搜索 / 命令等）；中间思考默认折叠成一两行摘要；改动文件单独列出，并显示 `+行数` / `−行数`。助手正文去重，避免流式增量与完整帧叠成两遍。

### 文档

- README 重写为可公开分享的部署手册（本地跑通 / VPS+frp / 配置 / API）；实现细节仍见 `docs/architecture.md`，不另拆「人看/AI 看」两份。

### 新增

- **项目白名单可同步/增删**：`POST /api/projects/sync` 从 Cursor CLI 状态合并新目录；`POST/DELETE /api/projects` 按路径增删；CLI 支持 `-sync-projects` / `-add-project`；App 项目页右上角「同步」一键导入。不必再手改 `config.json` 并重启。
- **本机程序管理**：服务端新增 `/api/programs` 与 `/api/apps/*`，可查看正在运行的前台应用，并启停白名单程序（默认 Cursor / frp 隧道 / 防睡眠）；App 增加「本机」页，支持开关、关闭与从 Applications 打开。
- **本机系统信息**：`GET /api/system` 汇总硬件、内存/交换、磁盘、电池、亮度、音量、网络（含 Wi‑Fi 信道与信号）、蓝牙已连接/已配对设备、负载与开机时长；运行中程序附带 RSS 内存占用。
- **本机页导航 + 远程调节**：顶部胶囊可快速跳到概览/内存/磁盘/电池/显示/网络/蓝牙/受管/运行中；亮度、音量支持滑杆远程调节（`POST /api/system/brightness|volume`，亮度经 `displayctl.py` 调 DisplayServices）。
- **App 图标资源位**：新增 `Assets.xcassets`（AppIcon 单尺寸 1024 版式），`project.yml` 里 `ASSETCATALOG_COMPILER_APPICON_NAME` 设为 `AppIcon`。当前放了一张占位图，直接把 `Assets.xcassets/AppIcon.appiconset/AppIcon.png` 换成正式图标即可。
- **App 侧 markdown 渲染**：Agent 返回的正文不再按纯文本显示，改为解析后渲染——标题、有序/无序列表（含嵌套）、引用、分隔线、表格，以及行内粗体、斜体、行内代码与可点击链接。
- 代码块单独排版：等宽字体、横向滚动、语言标签和一键复制；流式输出中未闭合的围栏按「到文末」处理，不会把后半段文字吞成正文。
- 解析结果按文本内容缓存（最多 12 份），流式追加时已渲染块不再重复解析。

### 变更

- `server/server` 编译产物不再入库（`.gitignore` 补规则），避免 `go build` 每次都把 9 MB 二进制改成工作区改动。
- App 内的使用说明改为当前实际部署（公网入口 + token 获取命令 + 白名单 + 睡眠限制），并新增「多人使用」说明：单实例单 token，不是一人一 token。
- README 补充 token 的生成 / 查看 / 轮换方式，以及为什么目前不能多人分权。
- App 的 token 持久化改为「Keychain 主存储 + 容器文件兜底」（`TokenStore`）：Keychain 读写失败不再静默丢弃，读不到时从 `Application Support/token` 恢复并回写；保存失败会在设置页提示。token 入库前去除首尾空白与换行。

### 修复

- **对话里以 `-` 开头的纯文本被当成 CLI 参数**：`buildArgs` 在 prompt 前加 `--` 结束选项解析；续聊发送「- 列表项」一类消息不再触发 `unknown option`。
- App 重启后 token 丢失、要重新填写（旧代码忽略 `SecItemAdd/CopyMatching` 的状态码，钥匙串失效时无感知）。
- **首次配置只要输入框非空就跳进主界面**：`isConfigured` 原先只看 `地址 + token` 是否非空，粘贴 token 的瞬间视图就切到主界面，`saveSettings()` 从未执行，token 因此一次都没落盘。现在改为以持久化标记 `cursorremote.configured` 为准，且必须「token 落盘成功 + 连接成功」才置位；退出登录会一并清除。
- **配置完成后切页卡顿、列表偶发空白**：
  - 保存流程改为「落盘 → 只等健康检查 → 立刻切页」，项目/任务列表在后台继续拉，不再让用户对着配置页等三个请求全部返回；切换加了淡入过渡。
  - `refresh()` 三个接口分别落地，任一接口抖动不再导致整页空白；启动与回到前台的并发刷新会合并成一次（此前会重复请求两批）。
  - 项目 / 任务列表为空且有请求在飞时显示骨架占位，不再闪「没有可用项目」；`ProjectsView` 增加了列表为空时自动补拉，不必手动下拉。

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
