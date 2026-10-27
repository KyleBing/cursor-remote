import Foundation
import os

/// token 持久化：Keychain 为主，App 容器文件兜底。
///
/// 旧实现只写 Keychain 且忽略 OSStatus，一旦钥匙串读写失败（重装、签名变化、
/// 设备迁移）就会静默丢 token，表现为「每次启动都要重新填 token」。
enum TokenStore {
    private static let log = Logger(subsystem: "cn.kylebing.cursorremote", category: "token")

    /// Keychain 里用的 account 名
    private static let account = "cursorremote.token"

    /// 兜底文件位置：Application Support/token
    private static var backupURL: URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        // 目录不存在时先建出来，否则写文件必失败
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("token")
    }

    /// 保存 token，返回是否至少有一处落盘成功
    @discardableResult
    static func save(_ token: String) -> Bool {
        // 手动粘贴常带换行/空格，先去掉再存
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog("save len=\(value.count)")
        guard !value.isEmpty else {
            clear()
            return false
        }
        let status = Keychain.set(value, for: account)
        if status != errSecSuccess {
            log.error("Keychain 写入失败 status=\(status)")
        }
        let backupOK = writeBackup(value)
        debugLog("save keychain=\(status) backup=\(backupOK)")
        return status == errSecSuccess || backupOK
    }

    /// 读取 token：Keychain 优先，读不到时用兜底文件恢复并回写
    static func load() -> String? {
        if let value = Keychain.get(account), !value.isEmpty {
            debugLog("load 命中 Keychain len=\(value.count)")
            return value
        }
        debugLog("load Keychain 无值")
        guard let value = readBackup(), !value.isEmpty else {
            debugLog("load 兜底文件也没有")
            return nil
        }
        log.notice("Keychain 无 token，已从兜底文件恢复")
        debugLog("load 命中兜底文件 len=\(value.count)")
        _ = Keychain.set(value, for: account)
        return value
    }

    /// 开发期打到 stderr 的诊断，Release 不输出
    private static func debugLog(_ msg: String) {
        #if DEBUG
        print("[TokenStore] \(msg)")
        #endif
    }

    /// 清除 token（Keychain 与兜底文件一起删）
    static func clear() {
        Keychain.delete(account)
        guard let url = backupURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 写兜底文件，带文件级数据保护（设备解锁后即可读）
    private static func writeBackup(_ value: String) -> Bool {
        guard let url = backupURL else { return false }
        do {
            try Data(value.utf8).write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            log.error("兜底文件写入失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 读兜底文件
    private static func readBackup() -> String? {
        guard let url = backupURL, let data = try? Data(contentsOf: url) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
