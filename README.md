# cursor-remote

在家用 iPad / iPhone 给公司 Mac 上的项目发指令，实时看 Cursor Agent 的执行过程，回家再打开 Cursor 验收。

```
iPad/iPhone App ──HTTPS──> 阿里云 nginx ──frp 隧道──> Mac 上的 Go 服务 ──> agent CLI（指定项目 cwd）
                                                          │
                                                          ├─ 任务队列 + 事件落盘（可断点续传）
                                                          ├─ SSE 实时推送
                                                          └─ 项目白名单 / token 鉴权
```

实现原理（链路各段职责、Cursor CLI 调用参数、流式与断点续传、headless 审批局限）见 **[docs/architecture.md](docs/architecture.md)**。

## 目录

```
cursor-remote/
├── docs/
│   └── architecture.md   实现原理：链路、CLI 调用、流式、审批取舍
├── server/                Go 服务端（仅标准库，无第三方依赖）
│   ├── main.go            启动、监听、优雅退出
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
├── relay/                 VPS 侧部署（frps + nginx）
│   └── setup-aliyun.sh    一键安装并注入现有 443 站点
└── scripts/
    ├── run-server.sh            编译并启动服务
    ├── install-launchagent.sh   注册服务端常驻
    ├── install-frpc.sh          注册 frpc 隧道常驻
    ├── install-caffeinate.sh    接电时阻止睡眠
    ├── install-ios.sh           编译并安装到真机
    └── check-network.sh         只读网络诊断
```

## 前置条件

1. **Cursor CLI**（服务端调用的就是它）
   ```bash
   curl https://cursor.com/install -fsS | bash
   ~/.local/bin/agent login     # 只需一次，浏览器授权
   ~/.local/bin/agent status    # 确认已登录
   ```

2. **跨网通路**（二选一，本机用方案 B）
   - **A. Tailscale**：Mac 与 iPad 装同一 tailnet，服务不暴露公网。注意与 Clash 类 fake-IP 代理的冲突，见 [docs/architecture.md](docs/architecture.md#网络选型为什么没用-tailscale)
   - **B. VPS 反向隧道**（当前采用）：阿里云 nginx + frp，Mac 只需出站，见「网络通路」章节

3. **Mac 保持唤醒**：接电源，`./scripts/install-caffeinate.sh` 会在接电时阻止睡眠；但**合盖仍会睡**。

## 跑起来

```bash
# 1. 启动服务端（前台，Ctrl-C 退出）
./scripts/run-server.sh

# 2. 首次启动会打印访问地址和 token，并生成 ~/.cursor-remote/config.json
```

输出示例：

```
监听: 127.0.0.1:8787
Agent: /Users/you/.local/bin/agent
项目: 16 个
Token: 3f2a...
```

App 首次打开时填 `https://kylebing.cn/cursor-remote` 和 token 即可（地址已内置为默认值）。

```bash
# 3. 装到真机（不带参数 = 第一个可用真机）
./scripts/install-ios.sh
./scripts/install-ios.sh "Kyle's iPad"

# 4. 注册常驻（开机自启、崩溃自动拉起）
./scripts/install-launchagent.sh   # Go 服务
./scripts/install-frpc.sh <vps_ip> <frp_token>   # frp 隧道
./scripts/install-caffeinate.sh    # 接电时阻止睡眠

# 卸载常驻
./scripts/install-launchagent.sh remove
./scripts/install-frpc.sh remove
./scripts/install-caffeinate.sh remove
```

## 配置

配置文件 `~/.cursor-remote/config.json`：

| 字段 | 说明 |
| --- | --- |
| `port` | 监听端口，默认 8787 |
| `token` | Bearer token，首次启动自动生成（32 字节随机，64 位 hex）；改完重启服务即轮换 |
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

- **网络**：公网入口为 `https://kylebing.cn/cursor-remote/`，TLS 由阿里云 nginx 终止；服务端本身只监听 `127.0.0.1`，外部流量只能经 frp 隧道进入。
- **鉴权**：32 字节随机 token，常数时间比较。`?token=` 参数**仅**对回环地址生效，公网请求只认 `Authorization: Bearer`。
- **目录**：请求里的项目必须命中白名单，防止远程执行任意路径。
- **审批**：默认 `--auto-review`，由服务端分类器放行安全命令、其余暂停；`--force` 需配置里显式打开 `allowForce`。
- **流量**：事件的 `raw` 字段只落盘用于复盘，不推给客户端（实测省 70% 流量）。

### token 怎么来、怎么换

| 事项 | 说明 |
| --- | --- |
| 生成 | 首次启动（`~/.cursor-remote/config.json` 不存在）或配置里 `token` 为空时，自动生成 32 字节随机串（64 位 hex）并写回配置 |
| 查看 | 启动横幅里的 `Token:` 一行；或 `server/bin/cursor-remote -print-token`；或直接看 `~/.cursor-remote/config.json` 的 `token` 字段（权限 0600） |
| 轮换 | 改 `config.json` 的 `token` → 重启服务（LaunchAgent：`launchctl kickstart -k gui/$(id -u)/cn.kylebing.cursorremote`）→ 所有设备重新填新 token |

### 多人使用：目前不支持

服务端是**单实例、单 token**：一个 token 就是全权凭据，能访问白名单里的所有项目、读写所有任务（含中断别人发起的任务）。任务没有记录发起者，也没有按人隔离的项目列表。

多台设备填同一个 token 是可以的，但那是「同一个人多台设备」，不是多人分权。真要给同事用，只有两条路：

1. 每人自己的 Mac 上各跑一套（各自的 `~/.cursor-remote/config.json`、白名单、token、隧道）；
2. 改造服务端：`token → 用户` 映射、任务记录 `owner`、按用户过滤列表与详情/SSE、白名单按用户分组——目前都还没做。

## 网络通路（家 → 公司）

服务端只跑在 Mac 上，iPad 需要一条跨网通路。两种选法：

| 方案 | 适用 | 说明 |
| --- | --- | --- |
| **Tailscale** | 公司允许装第三方 VPN | 零运维、免费、端到端加密、P2P 直连优先、DERP 兜底 |
| **VPS 反向隧道** | 公司不允许装 / 网络封锁 | Mac **只出站**连 VPS，公司不用开端口；需自己做 TLS |

> **本机最终采用：VPS 反向隧道。** 原因不是偏好，而是 Tailscale 在这台机器上撞上了两个硬阻碍：
> 1. Tailscale App 的网络扩展卡在 `activated waiting for user`，系统设置里没有可点的开关（早期安装残留所致），而 SIP 已开启、无法 `systemextensionsctl reset`；
> 2. 机器上常驻 **Clash Verge（TUN + fake-IP）**，与 Tailscale 同处隧道层，fake-IP 把 `controlplane.tailscale.com` 解析到 `198.18.x.x`，登录流程永远拿不到授权链接。
>
> 详见下面「本机实际部署」里的踩坑记录。

先在公司的 Mac 上跑诊断（只读，不安装）：

```bash
bash scripts/check-network.sh
```

它会检查控制面/DERP/出站连通性、MDM 管控状态、已有的坏安装，并给出结论。

若走 VPS 反向隧道，务必：

1. 服务端改成只监听 `127.0.0.1`（`-addr 127.0.0.1`），由 frp / Caddy 转发
2. 外层套 TLS（Caddy 自动证书），否则 token 在公网是明文
3. `?token=` 参数在公网会被拒（仅回环可用），App 用 Bearer 头不受影响

### 本机实际部署（阿里云 + 路径前缀）

链路：

```
iPad ──HTTPS──> kylebing.cn (阿里云 47.104.156.196)
                      │ nginx :443  复用现有证书
                      ▼
                127.0.0.1:8787 (frps)
                      │ frp 隧道（Mac 只出站连 :7000）
                      ▼
                Mac 127.0.0.1:8787 (Go 服务)
```

选用 `kylebing.cn` 而不是另一个域名的原因：它是自有域名、已完成备案、证书已在用，而且**不需要新增 DNS 记录**——直接挂在现有 443 站点的 `/cursor-remote/` 路径下。

VPS 侧（`relay/setup-aliyun.sh` 一条命令做完，幂等）：

```bash
scp /path/to/frps root@47.104.156.196:/tmp/frps
scp relay/setup-aliyun.sh root@47.104.156.196:/root/
ssh root@47.104.156.196 'bash /root/setup-aliyun.sh <frp_token>'
```

它会：装 `frps` → 写 systemd 单元（`MemoryMax=128M`，小机器友好）→ 写 nginx snippet → 在主配置里注入一行 `include` → `nginx -t` 校验通过才 reload。

Mac 侧：

```bash
./scripts/install-frpc.sh 47.104.156.196 <frp_token>
./scripts/install-caffeinate.sh   # 接电时阻止睡眠，否则隧道会断
```

访问地址：`https://kylebing.cn/cursor-remote/`

**踩过的坑：**

- **备份文件不能放在 `sites-enabled/`**。nginx 会加载该目录下*所有*文件，把 `default.bak.xxx` 放进去会立刻触发 `duplicate upstream "ws_server"`，`nginx -t` 直接失败。备份要放 `sites-enabled/` 之外（脚本里用 `/root/nginx-backups/`）。
- 在国内 VPS 上用 `sslip.io` / `nip.io` 这类免费域名申请证书会失败：ACME 验证返回 `403`，响应体是运营商的 `非法阻断743` 页面。未备案域名在国内服务器上会被运营商拦在出口，**必须用已备案的自有域名**。
- VPS 直连 GitHub 常年卡死（0 字节），frp 二进制要**在本机下载再 `scp` 上去**。
- `Clash` 这类 fake-IP 代理会和 Tailscale 抢隧道层：DNS 把控制面域名解析到 `198.18.x.x`，而 Tailscale 走自己的 utun 不经 Clash 路由，导致登录永远卡在 `doLogin(hasUrl=false)`。两者共存需把 `*.tailscale.com` 加进 `fake-ip-filter` 并加路由排除规则。
- **端口连通性不能用 `nc` 在本机测**：Clash TUN 会代理所有 TCP，连一个必然关闭的端口也返回「成功」。要么从另一台服务器测，要么直接打 HTTP 请求看响应内容。



## 带宽实测

单轮"重会话"（3000 字回答 + 80 次工具调用）实际传输 **约 107 KB**，连续流式峰值 **21 kbps**。
1 Mbps 的服务器绰绰有余（占用 2%），瓶颈从来不是带宽。

测量方法与优化细节见 [docs/architecture.md](docs/architecture.md#带宽优化)。

## 已知限制

1. **headless 下无法远程点"同意"**。`interaction_query` 由 CLI 本地策略自动应答，不走 stdin，所以手机上只能选审批档位，不能逐条批准。
2. **事件流里没有工具返回内容**。`stream-json` 只推 `tool_call started/completed` 与参数，命令输出请到 `~/.cursor/projects/<项目>/terminals/` 或直接看 transcript。
3. **Mac 必须醒着**，且服务需要常驻。已配两个 LaunchAgent（服务 + `caffeinate -s`）开机自启；但**合盖仍会睡眠**，远程使用需保持开盖。
4. **App 默认走 https**（`https://kylebing.cn/cursor-remote`），正规证书，实际不再需要 ATS 例外；`NSAllowsArbitraryLoads` 仅为兼容局域网 http 直连回退而保留。
5. **服务端只监听 `127.0.0.1`**，外部流量只能经 frp 隧道进来。这既省事也安全，但意味着**不能**再用 `http://<局域网IP>:8787` 直连；局域网调试请临时加 `-addr 0.0.0.0`。

## 后续可做

- 语音输入指令（`SFSpeechRecognizer`）
- 通知：任务完成推送到 iPad（`UNUserNotificationCenter` + 服务端 APNs）
- 只读浏览历史 transcript（`~/.cursor/projects/*/agent-transcripts/*.jsonl`）
- 多 Mac 支持（服务器地址切换）
