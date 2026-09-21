import Foundation

/// 汎用の使用量スナップショット。UI はプロバイダ固有の JSON を見ない。
struct UsageSnapshot: Codable, Equatable {
    var providerID: String
    var accountLabel: String?
    var plan: PlanInfo
    var meters: [UsageMeter]
    var spend: SpendMeter?
    var fetchedAt: Date
    var errorMessage: String?

    /// メーターがあれば最大％。API 費用だけなら金額。どちらも無ければ nil。
    func menuBarValue(language: AppLanguage) -> String? {
        if let worst = meters.map(\.displayPercent).max() {
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

    var displayUnit: SpendUnit { unit ?? .usd }

    var fraction: Double {
        guard remainingUSD == nil, let limitUSD, limitUSD > 0, !isUnlimited else { return 0 }
        return min(max(usedUSD / limitUSD, 0), 1)
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

    /// クレジット数。整数なら桁を落とす。
    static func formatCount(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if abs(value - value.rounded()) < 0.0005 {
            return String(format: "%.0f", value.rounded())
        }
        return String(format: "%.2f", value)
    }
}
