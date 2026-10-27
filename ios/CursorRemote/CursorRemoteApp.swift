import SwiftUI
import UIKit

@main
struct CursorRemoteApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// 根视图：未配置时先走引导页
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isConfigured {
                MainTabView()
            } else {
                SetupView()
            }
        }
        .task { await model.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台时刷新一次，避免看到过期数据
            if phase == .active {
                Task { await model.refresh() }
            }
        }
    }
}

/// 主界面：项目 / 任务 / 设置
struct MainTabView: View {
    var body: some View {
        TabView {
            ProjectsView()
                .tabItem { Label("项目", systemImage: "folder") }
            TasksView()
                .tabItem { Label("任务", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

/// 首次配置：填服务器地址与 token
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var connecting = false

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
                    Text("连接 Mac")
                } footer: {
                    Text("在 Mac 上运行 cursor-remote server，启动时会打印访问地址与 token，填到上面即可。两台设备需要在同一个 Tailscale 网络里。")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Spacer()
                            if connecting {
                                ProgressView()
                            } else {
                                Text("连接")
                            }
                            Spacer()
                        }
                    }
                    .disabled(model.baseURLText.trimmed.isEmpty || model.tokenText.isEmpty || connecting)

                    if let paste = UIPasteboard.general.string, !paste.isEmpty, model.tokenText.isEmpty {
                        Button("从剪贴板填入 Token") {
                            model.tokenText = paste.trimmed
                        }
                    }
                }
            }
            .navigationTitle("远程 Cursor")
        }
    }

    /// 保存并测试连接
    private func connect() {
        connecting = true
        error = nil
        Task {
            await model.saveSettings()
            connecting = false
            if model.health == nil {
                error = model.lastError ?? "连接失败，请检查地址与 token"
            }
        }
    }
}
