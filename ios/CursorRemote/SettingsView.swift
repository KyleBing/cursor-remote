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
                    Text("地址与 token 在 Mac 上启动 cursor-remote server 时打印。建议用 Tailscale 的 100.x 地址，不要暴露到公网。")
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
                        Text("1. Mac 上运行 server（go run . 或编译后执行）")
                        Text("2. 确认两台设备在同一 Tailscale 网络")
                        Text("3. Mac 保持不休眠，电源适配器常接")
                        Text("4. 在项目页选项目，填指令即可远程发起")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
