# cursor-remote

在家用 iPad / iPhone 给公司 Mac 上的项目发指令，实时看 Cursor Agent 的执行过程，回家再打开 Cursor 验收。

```
iPad App ──(Tailscale)──> Mac 上的 Go 服务 ──> cursor-agent CLI（指定项目 cwd）
                              │
                              ├─ 任务队列 + 事件落盘（可断点续传）
                              ├─ SSE 实时推送
                              └─ 项目白名单 / token 鉴权
```

## 目录

```
cursor-remote/
├── server/                Go 服务端（仅标准库，无第三方依赖）
│   ├── main.go            启动、监听、Tailscale 地址探测
│   ├── config.go          配置读写 + token 生成 + 项目白名单
│   ├── projects.go        从 ~/.cursor/agent-cli-state.json 发现项目
│   ├── task.go            任务模型、持久化、子进程生命周期
│   ├── parser.go          stream-json 事件解析
│   ├── api.go             HTTP 接口 + SSE
│   └── api_test.go        端到端测试（用 stub agent）
├── ios/                   SwiftUI App（iPhone / iPad 通用，iOS 17+）
│   ├── project.yml        xcodegen 工程定义
│   └── CursorRemote/
│       ├── AppModel.swift     全局状态
│       ├── TaskSession.swift  单任务订阅 / 重连 / 事件聚合
│       ├── APIClient.swift    接口 + SSE 解析
│       ├── Models.swift       数据模型
│       └── *View.swift        项目 / 任务 / 详情 / 设置
└── scripts/
    ├── run-server.sh      编译并启动服务
    └── install-ios.sh     编译并安装到真机
```

## 前置条件

1. **Cursor CLI**（服务端调用的就是它）
   ```bash
   curl https://cursor.com/install -fsS | bash
   ~/.local/bin/agent login     # 只需一次，浏览器授权
   ~/.local/bin/agent status    # 确认已登录
   ```

2. **Tailscale**（两台设备同一个 tailnet，服务不暴露公网）
   - Mac 与 iPad 都装 Tailscale 并登录同一账号

3. **Mac 保持唤醒**：接电源，系统设置里关闭自动休眠，或用 `caffeinate -s`。

## 跑起来

```bash
# 1. 启动服务端（前台，Ctrl-C 退出）
./scripts/run-server.sh

# 2. 首次启动会打印访问地址和 token，并生成 ~/.cursor-remote/config.json
```

输出示例：

```
监听: 0.0.0.0:8787
Tailscale: http://100.101.x.x:8787
Agent: /Users/you/.local/bin/agent
项目: 16 个
Token: 3f2a...
```

App 首次打开时把 `http://100.101.x.x:8787` 和 token 填进去即可。

```bash
# 3. 装到真机（不带参数 = 第一个可用真机）
./scripts/install-ios.sh
./scripts/install-ios.sh "Kyle's iPad"

# 4. 可选：注册成 LaunchAgent，开机自启、崩溃自动拉起
./scripts/install-launchagent.sh
./scripts/install-launchagent.sh remove   # 卸载
```

## 配置

配置文件 `~/.cursor-remote/config.json`：

| 字段 | 说明 |
| --- | --- |
| `port` | 监听端口，默认 8787 |
| `token` | Bearer token，首次启动自动生成 |
| `agentPath` | agent CLI 路径，自动探测 |
| `projects` | **项目白名单**，只有这里面的目录能被远程执行 |
| `defaultApproval` | `auto-review` / `default` / `force` |
| `allowForce` | 是否允许 App 选择"全部放行"，默认 `false` |
| `allowedModels` | 可选，模型白名单 |
| `extraArgs` | 追加给 CLI 的参数 |

改完重启服务生效。项目列表首次由 `~/.cursor/agent-cli-state.json` 自动推断，可手工增删。

## 接口

除 `/` 外都需要 `Authorization: Bearer <token>`。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 服务与 CLI 状态（含登录状态） |
| GET | `/api/projects` | 白名单项目 + 会话统计 |
| GET | `/api/tasks?limit=50` | 任务列表 |
| POST | `/api/tasks` | 新建任务 `{project,prompt,mode,model,approval}` |
| GET | `/api/tasks/{id}` | 任务详情 + 全量事件 |
| GET | `/api/tasks/{id}/stream?after=N` | SSE，`after` 用于断线续传 |
| POST | `/api/tasks/{id}/stop` | 中断 |
| POST | `/api/tasks/{id}/followup` | `--resume` 续聊 |

SSE 帧：`event: task`（元信息）、`event: event`（一条事件）、`event: done`（结束），另有 15 秒心跳注释行。

## 安全模型

- **网络**：只走 Tailscale，服务监听 `0.0.0.0` 但公网不可达（100.64/10 是运营商级 NAT 段）。
- **鉴权**：32 字节随机 token，常数时间比较。
- **目录**：请求里的项目必须命中白名单，防止远程执行任意路径。
- **审批**：默认 `--auto-review`，由服务端分类器放行安全命令、其余暂停；`--force` 需配置里显式打开 `allowForce`。

## 已知限制

1. **headless 下无法远程点"同意"**。`interaction_query` 由 CLI 本地策略自动应答，不走 stdin，所以手机上只能选审批档位，不能逐条批准。
2. **事件流里没有工具返回内容**。`stream-json` 只推 `tool_call started/completed` 与参数，命令输出请到 `~/.cursor/projects/<项目>/terminals/` 或直接看 transcript。
3. **Mac 必须醒着**，且服务需要常驻。长期用建议配 LaunchAgent 开机自启 + `caffeinate -s`。
4. **App 用 http**（Tailscale 内网），因此开了 `NSAllowsArbitraryLoads`。若要求更高可换 Tailscale 的 HTTPS 证书 + 去掉该 ATS 例外。

## 后续可做

- LaunchAgent 常驻，开机自启
- 语音输入指令（`SFSpeechRecognizer`）
- 通知：任务完成推送到 iPad（`UNUserNotificationCenter` + 服务端 APNs）
- 只读浏览历史 transcript（`~/.cursor/projects/*/agent-transcripts/*.jsonl`）
- 多 Mac 支持（服务器地址切换）
