import AppIntents
import WidgetKit

struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource { "Refresh" }
    static var description: IntentDescription {
        IntentDescription("Fetches the latest usage.")
    }

    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Provider")
    var providerID: String?

    init() {}

    init(providerID: String?) {
        self.providerID = providerID
    }

    func perform() async throws -> some IntentResult {
        if let providerID, !providerID.isEmpty {
            AppSettings.noteNeededProvider(providerID)
        }
        AppSettings.requestKeychainRetry()
        AppSettings.notifyManualRefreshRequested()
        WidgetReloader.reload()
        return .result()
    }
}

struct TogglePauseIntent: AppIntent {
    static var title: LocalizedStringResource { "Pause or Resume Auto-Refresh" }
    static var description: IntentDescription {
        IntentDescription("Pauses or resumes automatic usage refresh.")
    }

    static var openAppWhenRun: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        AppSettings.isPaused = !AppSettings.isPaused
        AppSettings.notifyPauseStateChanged()
        WidgetReloader.reload()
        return .result()
    }
}

/// macOS のインタラクティブ・ウィジェットでは Link / widgetURL がボタンに負ける。
/// 拡張から URL は開けないので、メニューバー常駐へ通知してブラウザで開く。
struct OpenDashboardIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Dashboard" }
    static var description: IntentDescription {
        IntentDescription("Opens the plan and usage page in a browser.")
    }
    static var openAppWhenRun: Bool { true }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Provider")
    var providerID: String

    init() {
        providerID = UsageProviderRegistry.defaultProviderID
    }

    init(providerID: String) {
        self.providerID = providerID
    }

    func perform() async throws -> some IntentResult {
        let url = UsageProviderRegistry.provider(id: providerID)?.dashboardURL
            ?? URL(string: "https://cursor.com/dashboard?tab=usage")!
        AppSettings.notifyOpenDashboard(url: url)
        return .result()
    }
}
