import SwiftUI

/// 本机页分区，用于顶部 4×2 格子导航
private enum MacSection: String, CaseIterable, Identifiable {
    // 概览单独；内存+硬盘；电池+显示；其余各自一格
    case overview, storage, power, network, bluetooth, apps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .storage: return "存储"
        case .power: return "电源"
        case .network: return "网络"
        case .bluetooth: return "蓝牙"
        case .apps: return "应用"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "laptopcomputer"
        case .storage: return "internaldrive"
        case .power: return "battery.100"
        case .network: return "wifi"
        case .bluetooth: return "wave.3.right"
        case .apps: return "app.badge"
        }
    }
}

/// 本机：系统状态 + 受管程序启停 + 运行中应用
struct ProgramsView: View {
    @Environment(AppModel.self) private var model
    @State private var busyID: String?
    @State private var showOpenSheet = false
    @State private var actionError: String?
    @State private var activeSection: MacSection = .overview

    // 亮度 / 音量本地滑杆值（拖动时先更新 UI，松手或停顿后再请求）
    @State private var brightnessSlider: Double = 50
    @State private var volumeSlider: Double = 0
    @State private var mutedToggle = true
    @State private var controlsReady = false
    @State private var brightnessTask: Task<Void, Never>?
    @State private var volumeTask: Task<Void, Never>?
    @State private var controlBusy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sectionTabBar
                Divider()
                pageList
            }
            .navigationTitle("本机")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if model.systemInfo == nil {
                    await reload()
                } else {
                    syncControlsFromModel()
                }
            }
            .onChange(of: model.systemInfo?.at) { _, _ in
                if !controlBusy {
                    syncControlsFromModel()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showOpenSheet = true
                    } label: {
                        Image(systemName: "plus.app")
                    }
                    .accessibilityLabel("打开应用")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showOpenSheet) {
                OpenAppSheet { opened in
                    showOpenSheet = false
                    if opened {
                        Task { await reload() }
                    }
                }
            }
        }
    }

    // MARK: - 顶部分区格子（4 列，点击切换，无横向滚动）

    private var sectionTabBar: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(MacSection.allCases) { section in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        activeSection = section
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.icon)
                            .font(.body.weight(.semibold))
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(activeSection == section
                                ? Color.accentColor.opacity(0.16)
                                : Color(.tertiarySystemFill))
                    )
                    .foregroundStyle(activeSection == section ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// 当前分区对应的独立列表页
    private var pageList: some View {
        List {
            if let error = actionError ?? model.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            pageContent
        }
        .listStyle(.insetGrouped)
        .refreshable { await reload() }
        // 切换分区时带一点过渡，避免内容硬切
        .animation(.easeInOut(duration: 0.15), value: activeSection)
    }

    // MARK: - 各分区页面内容

    @ViewBuilder
    private var pageContent: some View {
        switch activeSection {
        case .overview:
            overviewPage
        case .storage:
            // 内存 + 硬盘
            memorySection
            diskSection
        case .power:
            // 电池 + 显示
            batterySection
            displayPage
        case .network:
            networkPage
        case .bluetooth:
            bluetoothPage
        case .apps:
            programsPage
            runningPage
        }
    }

    @ViewBuilder
    private var overviewPage: some View {
        if let info = model.systemInfo {
            Section {
                // 概览完整显示、可换行，不截断
                InfoRow(label: "机型", value: "\(info.hardware.modelName) · \(info.hardware.chip)", multiline: true)
                InfoRow(label: "标识", value: info.hardware.modelIdentifier, multiline: true)
                if let cores = info.hardware.cores {
                    InfoRow(label: "核心", value: cores, multiline: true)
                }
                InfoRow(label: "内存", value: "\(info.hardware.memoryGB) GB", multiline: true)
                InfoRow(label: "已开机", value: info.uptimeText, multiline: true)
                InfoRow(label: "负载", value: info.loadText, multiline: true)
                if let sn = info.hardware.serialNumber, !sn.isEmpty {
                    InfoRow(label: "序列号", value: sn, multiline: true)
                }
            }
        } else {
            loadingOrEmpty("正在读取本机信息…")
        }
    }

    @ViewBuilder
    private var memorySection: some View {
        if let info = model.systemInfo {
            Section {
                ProgressRow(
                    title: "已用 \(ByteFormat.string(info.memory.usedBytes))",
                    subtitle: "共 \(ByteFormat.string(info.memory.totalBytes))",
                    percent: info.memory.usedPercent,
                    warnAbove: 85
                )
                InfoRow(label: "压力", value: memoryPressureLabel(info.memory.pressure))
                if let swapUsed = info.memory.swapUsedBytes, let swapTotal = info.memory.swapTotalBytes, swapTotal > 0 {
                    InfoRow(label: "交换", value: "\(ByteFormat.string(swapUsed)) / \(ByteFormat.string(swapTotal))")
                }
            } header: {
                Text("内存")
            }
        } else if activeSection == .storage {
            loadingOrEmpty("正在读取内存…")
        }
    }

    @ViewBuilder
    private var diskSection: some View {
        if let info = model.systemInfo {
            Section {
                ForEach(info.disks) { disk in
                    ProgressRow(
                        title: disk.mount,
                        subtitle: "\(ByteFormat.string(disk.usedBytes)) / \(ByteFormat.string(disk.totalBytes)) · 剩余 \(ByteFormat.string(disk.freeBytes))",
                        percent: disk.usedPercent,
                        warnAbove: 90
                    )
                }
            } header: {
                Text("硬盘")
            }
        }
    }

    @ViewBuilder
    private var batterySection: some View {
        if let info = model.systemInfo {
            Section {
                if info.battery.present {
                    ProgressRow(
                        title: "\(info.battery.percent)% · \(info.battery.statusText)",
                        subtitle: info.battery.detail,
                        percent: Double(info.battery.percent),
                        warnAbove: 20,
                        invertWarn: true
                    )
                } else {
                    Text("无电池信息")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("电池")
            }
        } else if activeSection == .power {
            loadingOrEmpty("正在读取电池…")
        }
    }

    @ViewBuilder
    private var displayPage: some View {
        if model.systemInfo != nil {
            Section {
                brightnessControl
                volumeControl
                if let nits = model.systemInfo?.display.nits {
                    InfoRow(
                        label: "亮度",
                        value: String(format: "%.0f nits · 自动%@", nits, model.systemInfo?.display.autoBrightness == true ? "开" : "关")
                    )
                }
            } header: {
                Text("显示")
            } footer: {
                Text("拖动滑杆即可远程调节 Mac 亮度与音量。")
            }
        } else if activeSection == .power {
            loadingOrEmpty("正在读取显示与声音…")
        }
    }

    @ViewBuilder
    private var networkPage: some View {
        if let info = model.systemInfo {
            Section {
                InfoRow(label: "接口", value: info.network.primaryInterface)
                // IP 类字段高亮，便于一眼复制辨认
                if let ip = info.network.ipv4 { InfoRow(label: "IPv4", value: ip, highlighted: true) }
                if let gw = info.network.gateway { InfoRow(label: "网关", value: gw, highlighted: true) }
                if let dns = info.network.dns, !dns.isEmpty {
                    InfoRow(label: "DNS", value: dns.joined(separator: ", "), highlighted: true, multiline: true)
                }
                if let wifi = info.network.wifi, wifi.connected {
                    if let ssid = wifi.ssid, !ssid.isEmpty {
                        InfoRow(label: "Wi‑Fi", value: ssid)
                    } else {
                        InfoRow(label: "Wi‑Fi", value: "已连接")
                    }
                    if let ch = wifi.channel { InfoRow(label: "信道", value: ch) }
                    if let phy = wifi.phyMode { InfoRow(label: "协议", value: phy) }
                    if let sig = wifi.signalDBm {
                        let noise = wifi.noiseDBm.map { " / \($0)" } ?? ""
                        InfoRow(label: "信号", value: sig + noise)
                    }
                    if let rate = wifi.transmitMbps {
                        InfoRow(label: "速率", value: "\(rate) Mbps")
                    }
                }
                if let v6 = info.network.ipv6 {
                    InfoRow(label: "IPv6", value: v6, highlighted: true, multiline: true)
                }
            }
        } else {
            loadingOrEmpty("正在读取网络…")
        }
    }

    @ViewBuilder
    private var bluetoothPage: some View {
        if let info = model.systemInfo {
            Section {
                InfoRow(label: "蓝牙", value: info.bluetooth.on ? "开启" : "关闭")
                if info.bluetooth.connected.isEmpty {
                    Text("无已连接设备")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(info.bluetooth.connected) { device in
                        BluetoothRow(device: device)
                    }
                }
            } header: {
                Text("已连接")
            }

            if !info.bluetooth.paired.isEmpty {
                Section {
                    ForEach(info.bluetooth.paired) { device in
                        BluetoothRow(device: device)
                    }
                } header: {
                    Text("已配对未连接")
                }
            }
        } else {
            loadingOrEmpty("正在读取蓝牙…")
        }
    }

    @ViewBuilder
    private var programsPage: some View {
        Section {
            if model.programs.isEmpty {
                if model.isLoading {
                    ForEach(0..<3, id: \.self) { _ in
                        ProgramRow(program: .placeholder, busy: false) {}
                            .redacted(reason: .placeholder)
                    }
                } else {
                    Text("暂无受管程序")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.programs) { program in
                    ProgramRow(program: program, busy: busyID == program.id) {
                        Task { await toggle(program) }
                    }
                }
            }
        } header: {
            Text("受管")
        } footer: {
            Text("在 ~/.cursor-remote/config.json 的 programs 里配置。默认含 Cursor、frp 隧道、防睡眠。")
        }
    }

    @ViewBuilder
    private var runningPage: some View {
        Section {
            if model.runningApps.isEmpty {
                if model.isLoading {
                    ForEach(0..<3, id: \.self) { _ in
                        RunningAppRow(app: .placeholder, busy: false) {}
                            .redacted(reason: .placeholder)
                    }
                } else {
                    Text("没有正在运行的前台应用")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.runningApps) { app in
                    RunningAppRow(app: app, busy: busyID == app.id) {
                        Task { await quit(app) }
                    }
                }
            }
        } header: {
            Text("运行中")
        } footer: {
            Text("按内存占用从高到低排列；仅前台 GUI 应用。系统关键进程不可关闭。")
        }
    }

    @ViewBuilder
    private func loadingOrEmpty(_ text: String) -> some View {
        Section {
            if model.isLoading {
                HStack {
                    ProgressView()
                    Text(text)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("暂无数据，下拉刷新")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 亮度 / 音量控制

    private var brightnessControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("亮度", systemImage: "sun.max.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                // 百分比与 loading 同宽占位，避免出现/消失时左右跳动
                Text("\(Int(brightnessSlider.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .opacity(controlBusy ? 0 : 1)
                    .overlay {
                        if controlBusy {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .frame(minWidth: 36, alignment: .trailing)
            }
            Slider(value: $brightnessSlider, in: 0...100, step: 1) { editing in
                if !editing {
                    scheduleBrightnessApply()
                }
            }
            .onChange(of: brightnessSlider) { _, _ in
                guard controlsReady else { return }
                scheduleBrightnessApply()
            }
            .tint(.orange)
        }
        .padding(.vertical, 4)
    }

    private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("音量", systemImage: mutedToggle ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(mutedToggle ? "静音" : "\(Int(volumeSlider.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Toggle("静音", isOn: $mutedToggle)
                    .labelsHidden()
                    .onChange(of: mutedToggle) { _, newValue in
                        guard controlsReady else { return }
                        Task { await applyVolume(muted: newValue) }
                    }
            }
            Slider(value: $volumeSlider, in: 0...100, step: 1) { editing in
                if !editing {
                    // 拖动结束时若当前静音则自动取消静音
                    scheduleVolumeApply(unmuteIfNeeded: true)
                }
            }
            .onChange(of: volumeSlider) { _, _ in
                guard controlsReady else { return }
                scheduleVolumeApply(unmuteIfNeeded: false)
            }
            .disabled(mutedToggle && volumeSlider == 0)
            .tint(.accentColor)
        }
        .padding(.vertical, 4)
    }

    /// 从模型同步滑杆（刷新后）
    private func syncControlsFromModel() {
        guard let info = model.systemInfo else { return }
        controlsReady = false
        brightnessSlider = Double(info.display.brightnessPct)
        volumeSlider = Double(info.audio.outputVolume)
        mutedToggle = info.audio.muted
        // 下一拍再允许 onChange 触发请求，避免同步时误发
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            controlsReady = true
        }
    }

    private func scheduleBrightnessApply() {
        brightnessTask?.cancel()
        brightnessTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            await applyBrightness()
        }
    }

    private func scheduleVolumeApply(unmuteIfNeeded: Bool) {
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            if unmuteIfNeeded && mutedToggle {
                mutedToggle = false
            }
            await applyVolume(muted: mutedToggle)
        }
    }

    private func applyBrightness() async {
        controlBusy = true
        actionError = nil
        defer { controlBusy = false }
        do {
            try await model.setBrightness(percent: Int(brightnessSlider.rounded()))
        } catch {
            actionError = error.localizedDescription
            syncControlsFromModel()
        }
    }

    private func applyVolume(muted: Bool) async {
        controlBusy = true
        actionError = nil
        defer { controlBusy = false }
        do {
            try await model.setVolume(percent: Int(volumeSlider.rounded()), muted: muted)
        } catch {
            actionError = error.localizedDescription
            syncControlsFromModel()
        }
    }

    // MARK: - 数据

    private func reload() async {
        await model.refreshPrograms()
        syncControlsFromModel()
    }

    private func memoryPressureLabel(_ raw: String?) -> String {
        switch raw {
        case "critical": return "严重"
        case "warn": return "警告"
        case "normal": return "正常"
        default: return raw ?? "—"
        }
    }

    private func toggle(_ program: ProgramStatus) async {
        busyID = program.id
        actionError = nil
        await model.toggleProgram(program)
        if let err = model.lastError { actionError = err }
        busyID = nil
    }

    private func quit(_ app: RunningApp) async {
        busyID = app.id
        actionError = nil
        await model.quitRunningApp(app)
        if let err = model.lastError { actionError = err }
        busyID = nil
    }
}

// MARK: - 行组件

private struct InfoRow: View {
    let label: String
    let value: String
    var highlighted: Bool = false
    // 完整显示并可换行；value 最多扩到距 label 右侧 40pt
    var multiline: Bool = false

    var body: some View {
        HStack(alignment: multiline ? .top : .firstTextBaseline, spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 40)
            Text(value)
                .font(highlighted ? .subheadline.monospaced().weight(.semibold) : .subheadline)
                .foregroundStyle(highlighted ? Color.accentColor : .primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(multiline ? nil : 1)
                .fixedSize(horizontal: false, vertical: multiline)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline)
    }
}

private struct ProgressRow: View {
    let title: String
    let subtitle: String?
    let percent: Double
    var warnAbove: Double = 90
    var invertWarn: Bool = false

    private var clamped: Double { min(100, max(0, percent)) }

    private var tint: Color {
        if invertWarn {
            return clamped <= warnAbove ? .orange : .accentColor
        }
        return clamped >= warnAbove ? .orange : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.0f%%", clamped))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: clamped, total: 100)
                .tint(tint)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BluetoothRow: View {
    let device: BluetoothDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(device.connected ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    if let type = device.type { Text(type) }
                    if let battery = device.battery, !battery.isEmpty {
                        Text("·")
                        Text(battery)
                    }
                    if let rssi = device.rssi {
                        Text("·")
                        Text(rssi)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch (device.type ?? "").lowercased() {
        case "mouse": return "computermouse"
        case "keyboard": return "keyboard"
        case "headphones", "headset": return "headphones"
        case "speaker": return "hifispeaker"
        case "gamepad": return "gamecontroller"
        case "mobile phone": return "iphone"
        default: return device.connected ? "wave.3.right" : "wave.3.right.circle"
        }
    }
}

private struct ProgramRow: View {
    let program: ProgramStatus
    let busy: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: program.kind == "launchagent" ? "gearshape.2.fill" : "app.fill")
                .font(.title3)
                .foregroundStyle(program.running ? Color.accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(program.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(program.kindLabel)
                    if program.running {
                        Text("·")
                        Text(ByteFormat.string(program.memoryBytes))
                    } else {
                        Text("·")
                        Text(program.detail ?? "已停止")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            if busy {
                ProgressView()
            } else {
                Toggle("", isOn: Binding(
                    get: { program.running },
                    set: { _ in onToggle() }
                ))
                .labelsHidden()
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RunningAppRow: View {
    let app: RunningApp
    let busy: Bool
    var onQuit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(ByteFormat.string(app.memoryBytes))
                        .fontWeight(.medium)
                    Text("·")
                    Text("pid \(app.pid)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if busy {
                ProgressView()
            } else {
                Button("关闭", role: .destructive, action: onQuit)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }
}

private struct OpenAppSheet: View {
    var onDone: (Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [AvailableApp] = []
    @State private var filter = ""
    @State private var loading = true
    @State private var opening: String?
    @State private var error: String?

    private var filtered: [AvailableApp] {
        let q = filter.trimmed.lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("加载应用列表…")
                } else if let error {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    List(filtered) { app in
                        Button {
                            Task { await open(app) }
                        } label: {
                            HStack {
                                Text(app.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if opening == app.id {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(opening != nil)
                    }
                    .searchable(text: $filter, prompt: "搜索应用")
                }
            }
            .navigationTitle("打开应用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onDone(false)
                        dismiss()
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        guard let client = model.client else {
            error = "尚未配置服务器"
            return
        }
        do {
            apps = try await client.availableApps().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ app: AvailableApp) async {
        opening = app.id
        error = nil
        do {
            try await model.openAvailableApp(app)
            onDone(true)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            opening = nil
        }
    }
}
