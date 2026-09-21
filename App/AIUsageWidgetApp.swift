import SwiftUI
import WidgetKit
import AppIntents
import AppKit

@main
struct AIUsageWidgetApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Label(model.menuBarTitle, systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class UsageModel: ObservableObject {
    private static let refreshInterval: TimeInterval = 5 * 60

    @Published var selectedProviderID: String {
        didSet {
            guard selectedProviderID != oldValue else { return }
            AppSettings.selectedProviderID = selectedProviderID
            cookieDraft = ""
            hasManualCookie = selectedProvider?.loadManualCredential() != nil
            snapshot = AppSettings.snapshot(providerID: selectedProviderID)
            errorText = snapshot?.errorMessage
            Task { await refresh() }
        }
    }
    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            AppSettings.language = language
            AppSettings.notifyLanguageChanged()
            WidgetReloader.reload()
            objectWillChange.send()
        }
    }
    @Published var snapshot: UsageSnapshot?
    @Published var errorText: String?
    @Published var cookieDraft = ""
    @Published private(set) var isPaused: Bool
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasManualCookie = false

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false

    init() {
        selectedProviderID = AppSettings.selectedProviderID
        language = AppSettings.language
        isPaused = AppSettings.isPaused
        hasManualCookie = UsageProviderRegistry.provider(id: selectedProviderID)?.loadManualCredential() != nil
        snapshot = AppSettings.snapshot(providerID: selectedProviderID)
        if !AppSettings.isUsingAppGroup {
            errorText = L10n.string("menu.teamEmpty", language: language)
        }
        observePauseChangesFromWidget()
        observeManualRefreshRequestsFromWidget()
        observeOpenDashboardRequestsFromWidget()
        openPendingDashboard()
        if !isPaused {
            startTimer()
            Task { await refresh() }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func observePauseChangesFromWidget() {
        DistributedNotificationCenter.default().addObserver(
            forName: .pauseStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncPauseState() }
        }
    }

    private func observeManualRefreshRequestsFromWidget() {
        DistributedNotificationCenter.default().addObserver(
            forName: .manualRefreshRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func observeOpenDashboardRequestsFromWidget() {
        DistributedNotificationCenter.default().addObserver(
            forName: .openDashboardRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openPendingDashboard() }
        }
    }

    private func openPendingDashboard() {
        guard let url = AppSettings.takePendingDashboardURL() else { return }
        usageLogger.debug("open dashboard \(url.absoluteString, privacy: .public)")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error {
                usageLogger.error("dashboard open failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func syncPauseState() {
        let shared = AppSettings.isPaused
        guard shared != isPaused else { return }
        if shared { pause(propagate: false) } else { resume(propagate: false) }
    }

    var selectedProvider: (any UsageProvider)? {
        UsageProviderRegistry.provider(id: selectedProviderID)
    }

    var menuBarTitle: String {
        if isPaused { return L10n.string("menu.paused", language: language) }
        let providerKey = selectedProvider?.displayNameKey ?? "provider.cursor"
        guard let snapshot, let value = snapshot.menuBarValue(language: language) else {
            return L10n.string(providerKey, language: language)
        }
        return value
    }

    var menuBarSymbol: String {
        if isPaused { return "chart.bar" }
        if let errorText, !errorText.isEmpty { return "exclamationmark.triangle.fill" }
        return "chart.bar.fill"
    }

    func pause(propagate: Bool = true) {
        isPaused = true
        timer?.invalidate()
        timer = nil
        if propagate {
            AppSettings.isPaused = true
            WidgetReloader.reload()
        }
    }

    func resume(propagate: Bool = true) {
        isPaused = false
        if propagate { AppSettings.isPaused = false }
        startTimer()
        Task { await refresh() }
    }

    func refreshFromUser() async {
        AppSettings.requestKeychainRetry()
        await refresh()
    }

    func refresh() async {
        if refreshTask != nil {
            refreshAgain = true
            await refreshTask?.value
            return
        }
        let task = Task { @MainActor in
            self.isRefreshing = true
            defer {
                self.isRefreshing = false
                // 完了より先に外す。所有者が再開する前の要求が、終わったタスクを掴まないようにする。
                self.refreshTask = nil
            }
            repeat {
                self.refreshAgain = false
                await self.performRefresh()
            } while self.refreshAgain
        }
        refreshTask = task
        await task.value
        if refreshAgain {
            await refresh()
        }
    }

    private func performRefresh() async {
        if AppSettings.consumeKeychainRetry() {
            ClaudeSession.retryKeychainAccess()
        }

        let providerIDs = await providersToRefresh()
        for providerID in providerIDs {
            guard let provider = UsageProviderRegistry.provider(id: providerID) else { continue }
            do {
                let snap = try await provider.fetchSnapshot()
                AppSettings.saveSnapshot(snap)
                if providerID == selectedProviderID {
                    snapshot = snap
                    errorText = nil
                }
            } catch {
                guard !Self.isCancellation(error) else { continue }
                let message = Self.errorMessage(for: error, provider: provider, language: language)
                usageLogger.error("refresh failed: \(String(describing: error), privacy: .public)")
                if providerID == selectedProviderID {
                    errorText = message
                    if var existing = AppSettings.snapshot(providerID: providerID) {
                        existing.errorMessage = message
                        AppSettings.saveSnapshot(existing)
                        snapshot = existing
                    }
                }
            }
        }
        WidgetReloader.reload()
    }

    private func providersToRefresh() async -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        func append(_ id: String) {
            if seen.insert(id).inserted { ids.append(id) }
        }
        append(selectedProviderID)
        if let configured = await widgetConfiguredProviderIDs() {
            AppSettings.setNeededProviders(configured)
            for id in configured { append(id) }
        } else {
            for id in AppSettings.neededProviders { append(id) }
        }
        return ids
    }

    /// nil は問い合わせ失敗。空配列はウィジェットが無い。
    private func widgetConfiguredProviderIDs() async -> [String]? {
        let infos: [WidgetInfo]
        do {
            infos = try await withCheckedThrowingContinuation { continuation in
                WidgetCenter.shared.getCurrentConfigurations { continuation.resume(with: $0) }
            }
        } catch {
            usageLogger.error("getCurrentConfigurations に失敗: \(String(describing: error), privacy: .public)")
            return nil
        }
        var ids: [String] = []
        for info in infos {
            guard let intent = info.widgetConfigurationIntent(of: SelectProviderIntent.self) else {
                continue
            }
            ids.append(intent.resolvedProviderID)
        }
        return ids
    }

    func saveCookieDraft() {
        guard let provider = selectedProvider else { return }
        do {
            try provider.saveManualCredential(cookieDraft)
            cookieDraft = ""
            hasManualCookie = true
            errorText = nil
            Task { await refresh() }
        } catch {
            errorText = L10n.string(provider.authNeededKey, language: language)
        }
    }

    func clearCookie() {
        selectedProvider?.clearManualCredential()
        hasManualCookie = false
        cookieDraft = ""
        Task { await refresh() }
    }

    func openDashboard() {
        let url = UsageProviderRegistry.provider(id: selectedProviderID)?.dashboardURL
            ?? URL(string: "https://cursor.com/dashboard?tab=usage")!
        NSWorkspace.shared.open(url)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    private static func errorMessage(for error: Error, provider: any UsageProvider, language: AppLanguage) -> String {
        if let api = error as? UsageAPIError {
            switch api {
            case .unauthorized:
                return L10n.string("error.unauthorized.\(provider.id)", language: language)
            case .rateLimited:
                return L10n.string("error.rateLimited", language: language)
            case .apiKeyMode:
                return L10n.string("error.apiKeyMode.\(provider.id)", language: language)
            case .httpStatus, .decodeFailed:
                return L10n.format("error.network", api.localizedDescription, language: language)
            }
        }
        if let claude = error as? ClaudeSessionError {
            switch claude {
            case .apiKeyMode:
                return L10n.string("error.apiKeyMode.claude", language: language)
            case .keychainDenied:
                return L10n.string("error.keychainDenied.claude", language: language)
            case .tokenMissing, .tokenExpired, .invalidToken:
                return L10n.string(provider.authNeededKey, language: language)
            }
        }
        if let chatgpt = error as? ChatGPTSessionError, chatgpt == .apiKeyMode {
            return L10n.string("error.apiKeyMode.chatgpt", language: language)
        }
        if error is CursorSessionError || error is ClaudeSessionError || error is ChatGPTSessionError {
            return L10n.string(provider.authNeededKey, language: language)
        }
        return L10n.format("error.network", error.localizedDescription, language: language)
    }
}

struct MenuContent: View {
    @ObservedObject var model: UsageModel

    private var lang: AppLanguage { model.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            providerRow
            Divider()
            usageBody
            Divider()
            languageRow
            authSection
            footer
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("plan.current", language: lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let plan = model.snapshot?.plan {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(plan.name)
                            .font(.title2.weight(.semibold))
                        if let price = plan.priceText {
                            Text(price)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(L10n.string(model.selectedProvider?.displayNameKey ?? "provider.cursor", language: lang))
                        .font(.title2.weight(.semibold))
                }
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var usageBody: some View {
        if let errorText = model.errorText {
            Label(errorText, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let snapshot = model.snapshot {
            if let reset = snapshot.plan.resetAt {
                Text(resetCaption(reset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let account = snapshot.accountLabel {
                Text(account)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(snapshot.meters) { meter in
                    MeterRow(meter: meter, language: lang, compact: false)
                }
            }

            if let spend = snapshot.spend {
                SpendRow(spend: spend, language: lang)
            }

            Text(L10n.format(
                "menu.lastUpdated",
                snapshot.fetchedAt.formatted(date: .omitted, time: .shortened),
                language: lang
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        } else if model.errorText == nil {
            ProgressView().controlSize(.small)
        }

        if model.isPaused {
            Label(L10n.string("menu.pausedHint", language: lang), systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var languageRow: some View {
        HStack {
            Text(L10n.string("menu.language", language: lang))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $model.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)
        }
    }

    private var providerRow: some View {
        HStack {
            Text(L10n.string("menu.provider", language: lang))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $model.selectedProviderID) {
                ForEach(UsageProviderRegistry.all.map { $0.id }, id: \.self) { id in
                    Text(L10n.string(
                        UsageProviderRegistry.provider(id: id)?.displayNameKey ?? id,
                        language: lang
                    )).tag(id)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
        }
    }

    @ViewBuilder
    private var authSection: some View {
        let provider = model.selectedProvider
        let needsAuth = model.errorText != nil || model.snapshot == nil
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("menu.cookieSection", language: lang))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(cookieHint)
                .font(.caption2)
                .foregroundStyle(needsAuth ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(L10n.string(provider?.credentialNameKey ?? "menu.credentialName.cursor", language: lang))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                TextField(L10n.string("menu.cookiePlaceholder", language: lang), text: $model.cookieDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Button(L10n.string("menu.saveCookie", language: lang)) {
                    model.saveCookieDraft()
                }
                .disabled(model.cookieDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.hasManualCookie {
                    Button(L10n.string("menu.clearCookie", language: lang), role: .destructive) {
                        model.clearCookie()
                    }
                }
            }
            .font(.caption)
        }
    }

    private var cookieHint: String {
        if model.hasManualCookie {
            return L10n.string("menu.credentialSaved", language: lang)
        }
        if model.errorText == nil, model.snapshot != nil, let provider = model.selectedProvider {
            return L10n.string(provider.usingAppKey, language: lang)
        }
        return L10n.string(model.selectedProvider?.authNeededKey ?? "menu.authNeeded", language: lang)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.openDashboard()
            } label: {
                Label(L10n.string("menu.openDashboard", language: lang), systemImage: "safari")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            HStack(spacing: 8) {
                Button(model.isPaused
                       ? L10n.string("menu.resume", language: lang)
                       : L10n.string("menu.pause", language: lang)) {
                    if model.isPaused { model.resume() } else { model.pause() }
                }
                Button(L10n.string("menu.refresh", language: lang)) {
                    Task { await model.refreshFromUser() }
                }
                Spacer(minLength: 8)
                Button(L10n.string("menu.quit", language: lang)) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .font(.caption)
    }

    private func resetCaption(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale(for: lang)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let dateText = formatter.string(from: date)
        var text = L10n.format("plan.reset", dateText, language: lang)
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day ?? 0
        if days >= 0 {
            text += L10n.format("plan.daysLeft", days, language: lang)
        }
        return text
    }
}

struct MeterRow: View {
    let meter: UsageMeter
    let language: AppLanguage
    var compact: Bool = false

    private var percent: Int { meter.displayPercent }
    private var fraction: Double { meter.barFraction }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.string(meter.titleKey, language: language))
                        .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
                    if !compact, let subtitleKey = meter.subtitleKey {
                        Text(L10n.string(subtitleKey, language: language))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(L10n.format("meter.percentUsed", percent, language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: fraction)
                .tint(meter.accent == .primary ? Color.accentColor : Color.secondary)
        }
    }
}

struct SpendRow: View {
    let spend: SpendMeter
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.string(spend.titleKey, language: language))
                    .font(.callout.weight(.medium))
                Spacer()
                Text(amountText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if spend.remainingUSD == nil {
                ProgressView(value: spend.isUnlimited ? 0 : spend.fraction)
                    .tint(Color.secondary)
            }
        }
    }

    private var amountText: String {
        spend.formattedAmount(language: language, compact: false)
    }
}
