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
                    .transition(.opacity)
            } else {
                SetupView()
                    .transition(.opacity)
            }
        }
        // 配置完成时做一次淡入切换，避免整屏硬切造成的跳动感
        .animation(.easeInOut(duration: 0.25), value: model.isConfigured)
        .task { await model.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台时刷新一次，避免看到过期数据
            if phase == .active {
                Task { await model.refresh() }
            }
        }
    }
}

/// 主分区：项目 / 任务 / 本机 / 设置
enum MainSection: Hashable {
    case projects, tasks, programs, settings
}

/// 主界面：iPhone 底栏 Tab；iPad 左侧边栏，更好用宽屏
struct MainTabView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    // iOS List selection 必须是 Optional
    @State private var section: MainSection? = .projects

    init() {
        // 底部 Tab 文字略放大，默认偏小
        let font = UIFont.systemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        UITabBarItem.appearance().setTitleTextAttributes(attrs, for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes(attrs, for: .selected)
    }

    private var currentSection: MainSection { section ?? .projects }

    var body: some View {
        // regular 宽屏用侧边栏；窄屏（含 iPad 分屏）回退到底栏
        if sizeClass == .regular {
            ipadSidebar
        } else {
            iphoneTabs
        }
    }

    private var iphoneTabs: some View {
        TabView(selection: Binding(
            get: { currentSection },
            set: { section = $0 }
        )) {
            ProjectsView()
                .tabItem { Label("项目", systemImage: "folder") }
                .tag(MainSection.projects)
            TasksView()
                .tabItem { Label("任务", systemImage: "list.bullet.rectangle") }
                .tag(MainSection.tasks)
            ProgramsView()
                .tabItem { Label("本机", systemImage: "laptopcomputer") }
                .tag(MainSection.programs)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(MainSection.settings)
        }
    }

    private var ipadSidebar: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section {
                    Label("项目", systemImage: "folder")
                        .tag(MainSection.projects)
                    Label("任务", systemImage: "list.bullet.rectangle")
                        .tag(MainSection.tasks)
                    Label("本机", systemImage: "laptopcomputer")
                        .tag(MainSection.programs)
                    Label("设置", systemImage: "gearshape")
                        .tag(MainSection.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("远程 Cursor")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            // 各页自带 NavigationStack，放在 detail 列即可
            switch currentSection {
            case .projects:
                ProjectsView()
            case .tasks:
                TasksView()
            case .programs:
                ProgramsView()
            case .settings:
                SettingsView()
            }
        }
        .navigationSplitViewStyle(.balanced)
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
                    Text("地址填服务端入口（如 https://kylebing.cn/cursor-remote）。token 在 Mac 上运行 server/bin/cursor-remote -print-token 获取，也可查看 ~/.cursor-remote/config.json。")
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
            .adaptiveReadableWidth(560)
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
