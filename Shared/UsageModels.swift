import Foundation

/// 汎用の使用量スナップショット。UI はプロバイダ固有の JSON を見ない。
struct UsageSnapshot: Codable, Equatable {
    var providerID: String
    var accountLabel: String?
    var plan: PlanInfo
    var meters: [UsageMeter]
    var spend: SpendMeter?
    /// 追加クレジットの前後に出す金額行。旧スナップショットには無い。
    var spends: [SpendMeter]? = nil
    var fetchedAt: Date
    var errorMessage: String?

    var spendRows: [SpendMeter] {
        if let spends, !spends.isEmpty { return spends }
        return spend.map { [$0] } ?? []
    }

    /// メーターがあれば最大％。クラウドクレジットのような補助枠は代表値から外す。
    /// API 費用だけなら金額。どちらも無ければ nil。
    func menuBarValue(language: AppLanguage) -> String? {
        let ranked = meters.filter { $0.omitFromMenuBar != true }
        let source = ranked.isEmpty ? meters : ranked
        if let worst = source.map(\.displayPercent).max() {
            return "\(worst)%"
        }
        if let spend {
            return spend.formattedAmount(language: language, compact: true)
        }
        return nil
    }

    static func empty(providerID: String, fetchedAt: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            providerID: providerID,
            accountLabel: nil,
            plan: PlanInfo(name: "—", priceText: nil, resetAt: nil),
            meters: [],
            spend: nil,
            fetchedAt: fetchedAt,
            errorMessage: nil
        )
    }
}

struct PlanInfo: Codable, Equatable {
    var name: String
    var priceText: String?
    var resetAt: Date?
}

struct UsageMeter: Codable, Equatable, Identifiable {
    var id: String
    /// L10n キー（例: "meter.cursorModels"）
    var titleKey: String
    var subtitleKey: String?
    /// 100 超も許容（オーバー使用）。API の生値（例: 0.37 = 0.37%）。
    var percentUsed: Double
    var accent: MeterAccent
    /// 大ウィジェット用の注記。旧スナップショットには無い。
    var noteKey: String? = nil
    /// メニューバーの代表％に含めない。nil は含める（旧スナップショット）。
    var omitFromMenuBar: Bool? = nil
    /// 字幕を日付つきで出すときだけ入る。`subtitleKey` は `%@` を含む。
    var expiresAt: Date? = nil

    func subtitle(language: AppLanguage) -> String? {
        guard let subtitleKey else { return nil }
        guard let expiresAt else {
            return L10n.string(subtitleKey, language: language)
        }
        let dateText = UsageFormatting.monthDay(expiresAt, language: language)
        return L10n.format(subtitleKey, dateText, language: language)
    }

    enum MeterAccent: String, Codable {
        case primary
        case secondary
    }

    /// ダッシュボード表示に寄せた整数％。0より大きく1未満は 1% に切り上げる。
    var displayPercent: Int {
        UsageFormatting.displayPercent(percentUsed)
    }

    var barFraction: Double {
        min(max(percentUsed / 100.0, 0), 1)
    }
}

struct SpendMeter: Codable, Equatable {
    var id: String
    var titleKey: String
    var noteKey: String?
    /// 使用額（ドル）
    var usedUSD: Double
    /// 上限（ドル）。nil は無制限
    var limitUSD: Double?
    var isUnlimited: Bool
    /// 残り残高。単位は `unit`。旧スナップショットには無い。
    var remainingUSD: Double? = nil
    /// nil はドル（旧スナップショット互換）。
    var unit: SpendUnit? = nil
    /// true のとき金額は残り / 上限。旧スナップショットには無い。
    var amountIsRemaining: Bool? = nil
    var subtitleKey: String? = nil
    var expiresAt: Date? = nil
    /// 小ウィジェット用の短い見出し。旧スナップショットには無い。
    var compactTitleKey: String? = nil

    var displayUnit: SpendUnit { unit ?? .usd }

    var fraction: Double {
        guard remainingUSD == nil, let limitUSD, limitUSD > 0, !isUnlimited else { return 0 }
        return min(max(usedUSD / limitUSD, 0), 1)
    }

    func subtitle(language: AppLanguage) -> String? {
        guard let subtitleKey else { return nil }
        guard let expiresAt else {
            return L10n.string(subtitleKey, language: language)
        }
        return L10n.format(subtitleKey, UsageFormatting.expiryDate(expiresAt, language: language), language: language)
    }

    func formattedAmount(language: AppLanguage, compact: Bool) -> String {
        if displayUnit == .credits {
            if let remaining = remainingUSD {
                let number = UsageFormatting.formatCount(remaining)
                return L10n.format(
                    compact ? "spend.credits.balance.compact" : "spend.credits.balance",
                    number,
                    language: language
                )
            }
            if isUnlimited {
                return L10n.string("spend.unlimited", language: language)
            }
        }
        if isUnlimited || limitUSD == nil {
            return L10n.format(
                compact ? "spend.amountUnlimited.compact" : "spend.amountUnlimited",
                usedUSD,
                language: language
            )
        }
        if amountIsRemaining == true {
            let remaining = max((limitUSD ?? 0) - usedUSD, 0)
            return L10n.format(
                compact ? "spend.remaining.compact" : "spend.remaining",
                remaining,
                limitUSD ?? 0,
                language: language
            )
        }
        return L10n.format(
            compact ? "spend.amount.compact" : "spend.amount",
            usedUSD,
            limitUSD ?? 0,
            language: language
        )
    }
}

enum SpendUnit: String, Codable, Equatable {
    case usd
    case credits
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case ja
    case en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ja: return "日本語"
        case .en: return "English"
        }
    }
}

enum UsageFormatting {
    /// Cursor ダッシュボードと同様、わずかな使用量も 0% に落とさず 1% と出す。
    static func displayPercent(_ value: Double) -> Int {
        if value <= 0 { return 0 }
        if value < 1 { return 1 }
        return Int(value.rounded())
    }

    static func expiryDate(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale(for: language)
        formatter.dateFormat = language == .ja ? "M月d日 H:mm" : "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    static func monthDay(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale(for: language)
        formatter.dateFormat = language == .ja ? "M月d日" : "MMM d"
        return formatter.string(from: date)
    }

    /// クレジット数。整数なら桁を落とす。
    static func formatCount(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if abs(value - value.rounded()) < 0.0005 {
            return String(format: "%.0f", value.rounded())
        }
        return String(format: "%.2f", value)
    }
}
