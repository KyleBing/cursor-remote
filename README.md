# cursor-remote

<img width="2333" height="1600" alt="远程任务" src="https://github.com/user-attachments/assets/9491d7b5-8418-47b3-b97a-86bd2f12bfe9" />


用 iPhone / iPad **远程操控公司 Mac 上的 Cursor Agent**：下发指令、看流式输出；顺带查看本机状态（内存/磁盘/电池/网络/蓝牙）、启停白名单程序、调节亮度与音量。

最终验收仍建议回到 Mac 上的 Cursor 里做——远程负责「下达 + 观察」，不负责「点完所有审批」。

```
手机 App ──HTTPS──> VPS nginx ──frp──> Mac Go 服务 ──> agent CLI（项目白名单 cwd）
                                      │
                                      ├─ 任务队列 + 事件落盘 + SSE
                                      ├─ 本机程序启停 / 系统信息
                                      └─ Bearer token 鉴权
```

更深的链路说明、CLI 参数、流式与审批局限见 [docs/architecture.md](docs/architecture.md)。

---

## 你需要什么

| 角色 | 要求 |
| --- | --- |
| Mac（跑 Agent 的那台） | macOS，已安装并能 `agent login` 的 [Cursor CLI](https://cursor.com/docs/cli) |
| 手机 | iOS 17+，用 Xcode 签到自己的设备（或后续 TestFlight） |
| 跨网（二选一） | **A.** Tailscale 等同网；**B.** 一台有公网 IP / 域名的 VPS（推荐：Mac 只出站，走 frp） |

本地调试可以不要 VPS：服务监听局域网，App 填 `http://<Mac局域网IP>:8787`。

---

## 5 分钟本地跑通（无公网）

在 Mac 上：

```bash
git clone https://github.com/KyleBing/cursor-remote.git
cd cursor-remote

# 1) Cursor CLI 已登录
~/.local/bin/agent status

# 2) 前台启动服务（首次会生成 ~/.cursor-remote/config.json 与 token）
./scripts/run-server.sh -addr 0.0.0.0
# 记下横幅里的 Token:
```

装 App 到已连接真机：

```bash
# 需本机有 Xcode + xcodegen，且能签你的 Team
brew install xcodegen   # 若尚未安装
./scripts/install-ios.sh
```

打开 App → 地址填 `http://<这台Mac的局域网IP>:8787` → 粘贴 token → 连接。

> 公网部署时服务应只听 `127.0.0.1`（见下文），局域网调试才用 `-addr 0.0.0.0`。

---

## 公网部署（VPS + frp，推荐）

目标形态：

```
手机 ──HTTPS──> 你的域名/VPS:443 (nginx)
                      │ proxy /cursor-remote/ → 127.0.0.1:8787
                      ▼
                   frps (VPS 本机)
                      │ Mac 出站连 VPS:7000
                      ▼
                   frpc → Mac 127.0.0.1:8787 (Go)
```

### 1. VPS：frps + nginx 路径

准备：已备案或可用的 HTTPS 站点、能 SSH 的 root、先在你电脑上下好对应架构的 `frps`（国内 VPS 直连 GitHub 常超时）。

```bash
# 本机
scp /path/to/frps root@<VPS_IP>:/tmp/frps
scp relay/setup-aliyun.sh root@<VPS_IP>:/root/

# VPS
ssh root@<VPS_IP> 'bash /root/setup-aliyun.sh <自定义_frp_token>'
```

脚本会：安装 frps（systemd）、写入 nginx snippet，并在现有 443 站点注入 `/cursor-remote/`。  
入口示例：`https://你的域名/cursor-remote/`。

也可手改 nginx，核心是：

```nginx
location /cursor-remote/ {
    proxy_pass http://127.0.0.1:8787/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 3600s;
}
```

### 2. Mac：服务 + 隧道 + 防睡眠

```bash
cd cursor-remote

# Go 服务常驻（默认 -addr 127.0.0.1）
./scripts/install-launchagent.sh

# frp 客户端常驻
./scripts/install-frpc.sh <VPS_IP> <同一个_frp_token>

# 接电时阻止睡眠（合盖仍会睡）
./scripts/install-caffeinate.sh
```

查看 / 打印 token：

```bash
server/bin/cursor-remote -print-token
# 或
grep token ~/.cursor-remote/config.json
```

App 地址填：`https://你的域名/cursor-remote`（不要末尾多余路径纠结；与 nginx `location` 一致即可）。

卸载常驻：

```bash
./scripts/install-launchagent.sh remove
./scripts/install-frpc.sh remove
./scripts/install-caffeinate.sh remove
```

### 3. 健康检查

```bash
TOKEN=$(server/bin/cursor-remote -print-token)

# 本机
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/api/health

# 公网（应返回 JSON，且 loggedIn 等字段正常）
curl -sS -H "Authorization: Bearer $TOKEN" https://你的域名/cursor-remote/api/health
```

---

## 配置

路径：`~/.cursor-remote/config.json`（权限建议 `0600`）。改完需重启服务：

```bash
launchctl kickstart -k "gui/$(id -u)/cn.kylebing.cursor-remote"
```

| 字段 | 说明 |
| --- | --- |
| `port` | 默认 `8787` |
| `token` | Bearer；空则启动时自动生成 |
| `agentPath` | agent CLI 路径，可自动探测 |
| `projects` | **项目白名单**（名 + 绝对路径）；首次可从 Cursor 状态推断 |
| `programs` | **可远程启停程序**（`app` / `launchagent`）；缺省含 Cursor、frp、防睡眠 |
| `defaultApproval` | `auto-review`（默认）/ `default` / `force` |
| `allowForce` | 是否允许手机选「全部放行」，默认 `false` |
| `allowedModels` | 可选模型白名单 |
| `extraArgs` | 追加给 CLI 的参数 |

`programs` 示例：

```json
"programs": [
  { "id": "cursor", "name": "Cursor", "kind": "app", "appName": "Cursor" },
  { "id": "frpc", "name": "frp 隧道", "kind": "launchagent", "label": "cn.kylebing.cursor-remote-frpc" }
]
```

---

## HTTP API

除 `GET /` 外均需：`Authorization: Bearer <token>`。  
公网请求**不要**把 token 放进 query；`?token=` 仅本机回环可用。

### Agent 任务

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 服务与 CLI 状态 |
| GET | `/api/projects` | 白名单项目 |
| GET | `/api/tasks?limit=50` | 任务列表 |
| POST | `/api/tasks` | 新建 `{project,prompt,mode,model,approval}` |
| GET | `/api/tasks/{id}` | 详情 + 事件 |
| GET | `/api/tasks/{id}/stream?after=N` | SSE 续传 |
| POST | `/api/tasks/{id}/stop` | 中断 |
| POST | `/api/tasks/{id}/followup` | 同会话续聊 `{prompt}` |

SSE：`event: task` / `event` / `done`，约 15s 心跳注释行。

### 本机程序与系统

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/programs` | 受管程序状态 + 运行中前台应用（含 RSS） |
| POST | `/api/programs/{id}/start` | 启动白名单项 |
| POST | `/api/programs/{id}/stop` | 停止 |
| GET | `/api/apps` | 运行中前台应用 |
| GET | `/api/apps/available` | `/Applications` 列表 |
| POST | `/api/apps/open` | `{name}` 或 `{path}`（限 Applications） |
| POST | `/api/apps/quit` | `{name}` 或 `{pid}` |
| GET | `/api/system` | 硬件/内存/磁盘/电池/亮度音量/网络/蓝牙/负载 |
| POST | `/api/system/brightness` | `{percent:0-100}` |
| POST | `/api/system/volume` | `{percent:0-100, muted?:bool}` |

亮度调节依赖同目录 `server/displayctl.py`（经 DisplayServices）；`run-server.sh` / `install-launchagent.sh` 会拷到 `server/bin/`。

---

## 仓库结构

```
cursor-remote/
├── server/                 Go 服务（标准库；亮度脚本为 Python3）
├── ios/                    SwiftUI App（iOS 17+，xcodegen）
├── relay/                  VPS：setup-aliyun.sh、frp 样例配置
├── scripts/                一键启动 / LaunchAgent / frpc / iOS 安装
└── docs/architecture.md    实现原理（给要改代码的人或 Agent）
```

常用脚本：

| 脚本 | 作用 |
| --- | --- |
| `scripts/run-server.sh` | 编译并前台运行 |
| `scripts/install-launchagent.sh` | 服务常驻 |
| `scripts/install-frpc.sh` | frpc 常驻 |
| `scripts/install-caffeinate.sh` | 接电防睡眠 |
| `scripts/install-ios.sh` | 编译安装到真机 |
| `scripts/check-network.sh` | 只读网络诊断 |

---

## 安全要点

- 服务公网场景只绑 `127.0.0.1`，TLS 在 VPS 终止。
- **一个 token = 全权**：能跑白名单项目、看任务、管本机程序与亮度音量。不是多用户系统。
- 项目路径必须在 `projects` 白名单；打开 App 路径限制在 Applications。
- 默认审批 `auto-review`；`force` 需 `allowForce: true`。
- 轮换 token：改配置 → 重启服务 → 所有设备重填。

---

## 已知限制

1. headless 下不能在手机上逐条点「同意」，只能选审批档位。
2. SSE 事件不含工具 stdout 全文；完整输出在 Mac 本机 terminals / transcript。
3. **合盖会睡**，远程使用需开盖（或外接显示器等保持唤醒策略）。
4. 单实例单 token，不支持多人分权。

---

## 给编码 Agent 的提示

不必另写第二份 README。改代码时优先读：

1. 本文件（部署与 API 契约）
2. [docs/architecture.md](docs/architecture.md)（CLI 调用、SSE、网络取舍）
3. `server/*.go`、`ios/CursorRemote/*`（实现）

约束：服务端尽量保持**无第三方 Go 依赖**；iOS 用 xcodegen 生成工程，勿提交 `ios/CursorRemote.xcodeproj` / `server/bin/`。

---

## License

[MIT](LICENSE) — Copyright (c) 2026 KyleBing

可自由使用、修改、分发与商用；衍生项目须保留本许可与版权声明（署名作者）。
