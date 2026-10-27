import SwiftUI

/// 设置：服务器地址、token、服务端状态
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var saved = false
    @State private var checking = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    TextField("https://kylebing.cn/cursor-remote", text: $model.baseURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token", text: $model.tokenText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("服务器")
                } footer: {
                    Text("地址填服务端入口，例如 https://kylebing.cn/cursor-remote。token 在 Mac 上获取：执行 server/bin/cursor-remote -print-token，或查看 ~/.cursor-remote/config.json 的 token 字段。")
                }

                Section {
                    Button {
                        save()
                    } label: {
                        HStack {
                            Spacer()
                            if checking {
                                ProgressView()
                            } else {
                                Text(saved ? "已保存" : "保存并测试")
                            }
                            Spacer()
                        }
                    }
                    .disabled(checking)
                }

                Section("服务端状态") {
                    if let h = model.health {
                        LabeledContent("Agent 路径", value: h.agentPath ?? "-")
                        LabeledContent("Agent 版本", value: h.version ?? "-")
                        LabeledContent("CLI 登录", value: h.loggedIn == true ? "已登录" : "未登录")
                        LabeledContent("项目数", value: "\(h.projects ?? model.projects.count)")
                        if let d = h.detail, !d.isEmpty {
                            LabeledContent("提示", value: d)
                        }
                    } else {
                        Text(model.lastError ?? "未连接")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("使用说明") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Mac 上装常驻服务：./scripts/install-launchagent.sh（开机自启、崩溃自动拉起）")
                        Text("2. 取 token：执行 server/bin/cursor-remote -print-token，或看 ~/.cursor-remote/config.json 的 token 字段")
                        Text("3. 地址填公网入口 https://kylebing.cn/cursor-remote（阿里云 nginx + frp 隧道），手机不必和 Mac 在同一个网络")
                        Text("4. 只有 config.json 里 projects 白名单中的目录能被远程执行")
                        Text("5. Mac 接电源并保持开盖，合盖会睡眠、隧道随之断开")
                        Text("6. 在项目页选项目、填指令即可发起；任务页可看进度与历史")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("一个 token 对应 Mac 上的一个服务实例，不是一人一 token。")
                        Text("多台设备填同一个 token，看到的是同一批项目和任务，也能互相中断对方发起的任务。")
                        Text("要给同事共用，需要各自在自己的 Mac 上跑一套服务（各自的白名单与 token）。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("多人使用")
                } footer: {
                    Text("怀疑 token 泄露：改 config.json 里的 token 后重启服务，所有设备都要重新填新 token。")
                }

                Section {
                    Button("断开并清除配置", role: .destructive) {
                        model.signOut()
                    }
                }
            }
            .navigationTitle("设置")
        }
    }

    /// 保存并立即验证连接
    private func save() {
        checking = true
        saved = false
        Task {
            await model.saveSettings()
            checking = false
            saved = model.health != nil
            if saved {
                // 两秒后恢复按钮文案
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                saved = false
            }
        }
    }
}
