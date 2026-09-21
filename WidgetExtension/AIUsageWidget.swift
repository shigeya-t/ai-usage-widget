import WidgetKit
import SwiftUI
import AppIntents

struct UsageEntry: TimelineEntry {
    let date: Date
    let providerID: String
    let snapshot: UsageSnapshot?
    let isPaused: Bool
    let language: AppLanguage

    static func placeholder(_ date: Date = Date()) -> UsageEntry {
        UsageEntry(
            date: date,
            providerID: UsageProviderRegistry.defaultProviderID,
            snapshot: sampleSnapshot,
            isPaused: false,
            language: AppSettings.language
        )
    }

    private static var sampleSnapshot: UsageSnapshot {
        UsageSnapshot(
            providerID: CursorProvider.id,
            accountLabel: nil,
            plan: PlanInfo(name: "Pro", priceText: "$20/mo", resetAt: Date().addingTimeInterval(11 * 24 * 3600)),
            meters: [
                UsageMeter(id: "cursor-models", titleKey: "meter.cursorModels", subtitleKey: "meter.cursorModels.subtitle", percentUsed: 100, accent: .primary),
                UsageMeter(id: "other-models", titleKey: "meter.otherModels", subtitleKey: nil, percentUsed: 100, accent: .secondary)
            ],
            spend: SpendMeter(id: "on-demand", titleKey: "spend.onDemand", noteKey: "spend.onDemand.note", usedUSD: 42.85, limitUSD: 50, isUnlimited: false),
            fetchedAt: Date(),
            errorMessage: nil
        )
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry.placeholder()
    }

    func snapshot(for configuration: SelectProviderIntent, in context: Context) async -> UsageEntry {
        let entry = buildEntry(configuration: configuration, now: Date())
        requestRefreshIfNeeded(entry)
        return entry
    }

    func timeline(for configuration: SelectProviderIntent, in context: Context) async -> Timeline<UsageEntry> {
        let now = Date()
        let entry = buildEntry(configuration: configuration, now: now)
        requestRefreshIfNeeded(entry)
        let next = entry.isPaused
            ? now.addingTimeInterval(60 * 60)
            : now.addingTimeInterval(5 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func requestRefreshIfNeeded(_ entry: UsageEntry) {
        AppSettings.noteNeededProvider(entry.providerID)
        let stale = entry.snapshot.map { Date().timeIntervalSince($0.fetchedAt) > 10 * 60 } ?? true
        if entry.snapshot == nil || (stale && !entry.isPaused) {
            // 5分ごとの自動更新。Keychain 拒否のやり直しは更新ボタンだけが要求する。
            AppSettings.notifyManualRefreshRequested()
        }
    }

    /// ウィジェット拡張は通信しない。App Group のスナップショットだけを使う。
    private func buildEntry(configuration: SelectProviderIntent, now: Date) -> UsageEntry {
        let providerID = configuration.resolvedProviderID
        return UsageEntry(
            date: now,
            providerID: providerID,
            snapshot: AppSettings.snapshot(providerID: providerID),
            isPaused: AppSettings.isPaused,
            language: AppSettings.language
        )
    }
}

struct AIUsageWidget: Widget {
    let kind = WidgetKind.usage

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectProviderIntent.self, provider: Provider()) { entry in
            AIUsageWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(nsColor: .windowBackgroundColor)
                }
        }
        .configurationDisplayName("AI使用量")
        .description("Cursor / Claude / ChatGPT のプランと使用量を表示します")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct AIUsageWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    private var lang: AppLanguage { entry.language }
    private var isSmall: Bool { family == .systemSmall }
    private var isLarge: Bool { family == .systemLarge }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .padding(.horizontal, isSmall ? 10 : 14)
                .padding(.vertical, isSmall ? 8 : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            headerButtons
                .padding(.top, isSmall ? 6 : 10)
                .padding(.trailing, isSmall ? 8 : 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            snapshotContent(snapshot)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string(
                    UsageProviderRegistry.provider(id: entry.providerID)?.displayNameKey ?? "provider.cursor",
                    language: lang
                ))
                    .font(.caption.weight(.semibold))
                Label(L10n.string("widget.placeholder", language: lang), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func snapshotContent(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: isSmall ? 5 : 8) {
            header(snapshot)
            ForEach(snapshot.meters) { meter in
                meterBlock(meter)
            }
            if let spend = snapshot.spend {
                spendBlock(spend)
            }
            if entry.isPaused {
                Text(L10n.string("menu.paused", language: lang))
                    .font(.system(size: isSmall ? 9 : 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func header(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: isSmall ? 1 : 2) {
            Text(providerTitle)
                .font(.system(size: isSmall ? 9 : 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(snapshot.plan.name)
                    .font(isSmall ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                    .lineLimit(1)
                if !isSmall, let price = snapshot.plan.priceText {
                    Text(price)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 右上ボタン分の余白（小は狭め）
                Spacer(minLength: isSmall ? 36 : 44)
            }
            if let reset = snapshot.plan.resetAt {
                Text(resetCaption(reset, compact: isSmall))
                    .font(.system(size: isSmall ? 9 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    private var providerTitle: String {
        L10n.string(
            UsageProviderRegistry.provider(id: entry.providerID)?.displayNameKey ?? "provider.cursor",
            language: lang
        )
    }

    private func meterBlock(_ meter: UsageMeter) -> some View {
        let percent = meter.displayPercent
        let fraction = meter.barFraction
        return VStack(alignment: .leading, spacing: isSmall ? 1 : 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(L10n.string(meter.titleKey, language: lang))
                    .font(.system(size: isSmall ? 10 : 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                Text("\(percent)%")
                    .font(.system(size: isSmall ? 8 : 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(0)
            }
            if !isSmall, let subtitleKey = meter.subtitleKey {
                Text(L10n.string(subtitleKey, language: lang))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            usageBar(fraction: fraction, primary: meter.accent == .primary)
            if isLarge, let noteKey = meter.noteKey {
                Text(L10n.string(noteKey, language: lang))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func spendBlock(_ spend: SpendMeter) -> some View {
        let amount = spendAmount(spend, compact: isSmall)
        let showBar = spend.remainingUSD == nil
        return VStack(alignment: .leading, spacing: isSmall ? 1 : 2) {
            if isSmall {
                // 金額が長いのでラベル行と分け、バー横に置く
                Text(L10n.string(spend.titleKey, language: lang))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if showBar {
                        usageBar(fraction: spend.isUnlimited ? 0 : spend.fraction, primary: false)
                    }
                    Text(amount)
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(L10n.string(spend.titleKey, language: lang))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 2)
                    Text(amount)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(0)
                }
                if showBar {
                    usageBar(fraction: spend.isUnlimited ? 0 : spend.fraction, primary: false)
                }
            }
            if isLarge, let noteKey = spend.noteKey {
                Text(L10n.string(noteKey, language: lang))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func usageBar(fraction: Double, primary: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(primary ? Color.accentColor : Color.secondary.opacity(0.7))
                    .frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: isSmall ? 4 : 6)
    }

    private var headerButtons: some View {
        HStack(spacing: isSmall ? 6 : 8) {
            Button(intent: TogglePauseIntent()) {
                Image(systemName: entry.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: isSmall ? 10 : 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(entry.isPaused ? .orange : .secondary)

            Button(intent: RefreshUsageIntent(providerID: entry.providerID)) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: isSmall ? 10 : 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func spendAmount(_ spend: SpendMeter, compact: Bool) -> String {
        spend.formattedAmount(language: lang, compact: compact)
    }

    private func resetCaption(_ date: Date, compact: Bool) -> String {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)
        ).day ?? 0

        let formatter = DateFormatter()
        formatter.locale = L10n.locale(for: lang)
        if lang == .ja {
            formatter.dateFormat = "M月d日"
        } else if compact {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        let dateText = formatter.string(from: date)

        if compact {
            return L10n.format("plan.reset.compact", dateText, max(days, 0), language: lang)
        }

        var text = L10n.format("plan.reset", dateText, language: lang)
        if days >= 0 {
            text += L10n.format("plan.daysLeft", days, language: lang)
        }
        return text
    }
}
