import Foundation
import Security

extension Notification.Name {
    static let pauseStateChanged = Notification.Name("jp.shigeya.AIUsageWidget.pauseStateChanged")
    static let manualRefreshRequested = Notification.Name("jp.shigeya.AIUsageWidget.manualRefreshRequested")
    static let openDashboardRequested = Notification.Name("jp.shigeya.AIUsageWidget.openDashboardRequested")
    static let languageChanged = Notification.Name("jp.shigeya.AIUsageWidget.languageChanged")
}

enum AppSettings {
    private static let groupSuffix = "jp.shigeya.AIUsageWidget"

    /// App Group は macOS では Team ID プレフィックスが必須。
    static let appGroupID: String = {
        let plist = (Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidGroupID(plist) { return plist }
        if let team = signingTeamID() {
            let resolved = "\(team).\(groupSuffix)"
            // Team ID を含むのでログには残さない
            usageLogger.error("Info.plist の AppGroupID が不正（\(plist, privacy: .private)）のため署名から組み立てます: \(resolved, privacy: .private)")
            return resolved
        }
        usageLogger.error("App Group を利用できません（AppGroupID=\(plist, privacy: .private)）")
        return plist
    }()

    private static func isValidGroupID(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix(".") && value.contains(".")
    }

    static var isUsingAppGroup: Bool { isValidGroupID(appGroupID) }

    private static func signingTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return team
        }
        if let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            if let team = entitlements["com.apple.developer.team-identifier"] as? String, !team.isEmpty {
                return team
            }
            if let appID = entitlements["com.apple.application-identifier"] as? String,
               let team = appID.split(separator: ".").first.map(String.init),
               team.count >= 8
            {
                return team
            }
        }
        return nil
    }

    private static var defaults: UserDefaults {
        guard isValidGroupID(appGroupID), let shared = UserDefaults(suiteName: appGroupID) else {
            return .standard
        }
        return shared
    }

    private enum Keys {
        static let isPaused = "isPaused"
        static let language = "language"
        static let selectedProviderID = "selectedProviderID"
        static let neededProviders = "neededProviders"
        static let pendingDashboardURL = "pendingDashboardURL"
        static let retryKeychain = "retryKeychain"
        static func snapshot(_ providerID: String) -> String { "snapshot.\(providerID)" }
    }

    static var isPaused: Bool {
        get { defaults.bool(forKey: Keys.isPaused) }
        set {
            defaults.set(newValue, forKey: Keys.isPaused)
            defaults.synchronize()
        }
    }

    static var language: AppLanguage {
        get {
            if let raw = defaults.string(forKey: Keys.language),
               let value = AppLanguage(rawValue: raw)
            {
                return value
            }
            return Locale.current.language.languageCode?.identifier == "ja" ? .ja : .en
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.language)
            defaults.synchronize()
        }
    }

    static var selectedProviderID: String {
        get {
            let raw = defaults.string(forKey: Keys.selectedProviderID) ?? ""
            return raw.isEmpty ? UsageProviderRegistry.defaultProviderID : raw
        }
        set {
            defaults.set(newValue, forKey: Keys.selectedProviderID)
            defaults.synchronize()
        }
    }

    static func notifyPauseStateChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            .pauseStateChanged,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func notifyManualRefreshRequested() {
        DistributedNotificationCenter.default().postNotificationName(
            .manualRefreshRequested,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// ウィジェットの更新ボタンからホストへ渡す。自動の timeline 更新では立てない。
    static func requestKeychainRetry() {
        defaults.set(true, forKey: Keys.retryKeychain)
        defaults.synchronize()
    }

    static func consumeKeychainRetry() -> Bool {
        guard defaults.bool(forKey: Keys.retryKeychain) else { return false }
        defaults.set(false, forKey: Keys.retryKeychain)
        defaults.synchronize()
        return true
    }

    static func notifyLanguageChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            .languageChanged,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// サンドボックスでは distributed notification の object / userInfo に任意の値を載せられない。
    static func notifyOpenDashboard(url: URL) {
        defaults.set(url.absoluteString, forKey: Keys.pendingDashboardURL)
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            .openDashboardRequested,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func takePendingDashboardURL() -> URL? {
        guard let raw = defaults.string(forKey: Keys.pendingDashboardURL), !raw.isEmpty else {
            return nil
        }
        defaults.removeObject(forKey: Keys.pendingDashboardURL)
        defaults.synchronize()
        guard let url = URL(string: raw), isAllowedDashboardURL(url) else {
            usageLogger.error("想定外のダッシュボード URL を破棄しました")
            return nil
        }
        return url
    }

    /// App Group は同一ユーザーの任意プロセスが書ける。distributed notification にも送信者の認証がない。
    /// 非サンドボックスの常駐アプリに任意の URL（`file://` を含む）を開かせないため、
    /// 登録済みプロバイダのダッシュボードだけを通す。
    static func isAllowedDashboardURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        return UsageProviderRegistry.all.contains { $0.dashboardURL == url }
    }

    /// App Group コンテナ。UserDefaults だけだと拡張側のキャッシュで古い値が残ることがある。
    private static var containerURL: URL? {
        guard isValidGroupID(appGroupID) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static func snapshotFileURL(providerID: String) -> URL? {
        containerURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("\(providerID).json", isDirectory: false)
    }

    private static let snapshotEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let snapshotDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func saveSnapshot(_ snapshot: UsageSnapshot) {
        guard let data = try? snapshotEncoder.encode(snapshot) else { return }

        if let fileURL = snapshotFileURL(providerID: snapshot.providerID) {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } catch {
                usageLogger.error("snapshot file write failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        defaults.set(data, forKey: Keys.snapshot(snapshot.providerID))
        defaults.synchronize()
    }

    static func snapshot(providerID: String) -> UsageSnapshot? {
        if let fileURL = snapshotFileURL(providerID: providerID),
           let data = try? Data(contentsOf: fileURL),
           let snap = try? snapshotDecoder.decode(UsageSnapshot.self, from: data)
        {
            return snap
        }
        // 旧形式（Date が reference interval）の UserDefaults も読む
        guard let data = defaults.data(forKey: Keys.snapshot(providerID)) else { return nil }
        if let snap = try? snapshotDecoder.decode(UsageSnapshot.self, from: data) {
            return snap
        }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    /// ウィジェットが設定したプロバイダ。getCurrentConfigurations が取れないときでもホストが取りに行く。
    static var neededProviders: [String] {
        defaults.stringArray(forKey: Keys.neededProviders) ?? []
    }

    static func noteNeededProvider(_ providerID: String) {
        var ids = neededProviders
        guard !ids.contains(providerID) else { return }
        ids.append(providerID)
        defaults.set(ids, forKey: Keys.neededProviders)
        defaults.synchronize()
    }

    /// 今置いてあるウィジェットのプロバイダで置き換える。外したものは残さない。
    static func setNeededProviders(_ ids: [String]) {
        var unique: [String] = []
        for id in ids where !unique.contains(id) {
            unique.append(id)
        }
        defaults.set(unique, forKey: Keys.neededProviders)
        defaults.synchronize()
    }
}
