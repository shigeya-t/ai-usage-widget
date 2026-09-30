import WidgetKit

enum WidgetKind {
    static let usage = "AIUsageWidget"
}

enum WidgetReloader {
    static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.usage)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// 再起動直後の `getCurrentConfigurations` は、ウィジェット復元前だと空配列になる。
/// その空を「ウィジェットが無い」と即採用すると、必要なプロバイダの取得が止まり、
/// デスクトップはプレースホルダのまま残る。空が続いたときだけ未配置として扱う。
enum WidgetConfigurationAdoption {
    static let emptyConfirmations = 3

    struct Decision: Equatable {
        var providers: [String]
        var replaceSaved: Bool
        var emptyStreak: Int
    }

    static func decide(configured: [String]?, saved: [String], emptyStreak: Int) -> Decision {
        guard let configured else {
            return Decision(providers: saved, replaceSaved: false, emptyStreak: emptyStreak)
        }
        if !configured.isEmpty {
            return Decision(providers: unique(configured), replaceSaved: true, emptyStreak: 0)
        }
        let next = emptyStreak + 1
        if next < emptyConfirmations && !saved.isEmpty {
            return Decision(providers: saved, replaceSaved: false, emptyStreak: next)
        }
        return Decision(providers: [], replaceSaved: true, emptyStreak: next)
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
