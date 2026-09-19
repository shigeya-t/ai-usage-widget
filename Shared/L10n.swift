import Foundation

enum L10n {
    static func string(_ key: String, language: AppLanguage = AppSettings.language) -> String {
        table[key]?[language] ?? table[key]?[.en] ?? key
    }

    static func format(_ key: String, _ args: CVarArg..., language: AppLanguage = AppSettings.language) -> String {
        String(format: string(key, language: language), locale: locale(for: language), arguments: args)
    }

    static func locale(for language: AppLanguage) -> Locale {
        switch language {
        case .ja: return Locale(identifier: "ja_JP")
        case .en: return Locale(identifier: "en_US")
        }
    }

    private static let table: [String: [AppLanguage: String]] = [
        "provider.cursor": [.ja: "Cursor", .en: "Cursor"],
        "plan.current": [.ja: "現在のプラン", .en: "CURRENT PLAN"],
        "plan.reset": [.ja: "使用量のリセット: %@", .en: "Usage limits reset on %@"],
        "plan.daysLeft": [.ja: "（残り%d日）", .en: " (%d days left)"],
        /// 小ウィジェット用（1行に収める）
        "plan.reset.compact": [.ja: "%@ · 残り%d日", .en: "%@ · %dd left"],
        "spend.amount.compact": [.ja: "$%.2f/$%.0f", .en: "$%.2f/$%.0f"],
        "spend.amountUnlimited.compact": [.ja: "$%.2f/∞", .en: "$%.2f/∞"],
        "included.in": [.ja: "%@ に含まれる使用量", .en: "Included in %@"],
        "meter.cursorModels": [.ja: "Cursor Models", .en: "Cursor Models"],
        "meter.cursorModels.subtitle": [
            .ja: "Cursor Grok と Composer を含む",
            .en: "Includes Cursor Grok and Composer"
        ],
        "meter.otherModels": [.ja: "Other Models", .en: "Other Models"],
        "meter.grokBot": [.ja: "Grok Bot", .en: "Grok Bot"],
        "meter.grokBot.subtitle": [.ja: "週次の利用枠", .en: "Weekly usage"],
        "meter.percentUsed": [.ja: "%d%% 使用", .en: "%d%% used"],
        "meter.cursorNote": [
            .ja: "上限を超えた追加使用は Other Models 枠またはオンデマンド課金に回ります。",
            .en: "Additional usage beyond limits consumes Other Models quota or on-demand spend."
        ],
        "meter.otherNote": [
            .ja: "上限を超えた追加使用はオンデマンド課金に回ります。",
            .en: "Additional usage beyond limits consumes on-demand spend."
        ],
        "spend.onDemand": [.ja: "オンデマンド", .en: "On-Demand"],
        "spend.onDemand.section": [.ja: "オンデマンド使用量", .en: "On-Demand Usage"],
        "spend.onDemand.note": [
            .ja: "上限を超えた使用は後からオンデマンドとして請求されます。",
            .en: "Usage past your limit is billed later as on-demand."
        ],
        "spend.unlimited": [.ja: "無制限", .en: "Unlimited"],
        "spend.amount": [.ja: "$%.2f / $%.0f", .en: "$%.2f / $%.0f"],
        "spend.amountUnlimited": [.ja: "$%.2f / 無制限", .en: "$%.2f / Unlimited"],
        "menu.paused": [.ja: "停止中", .en: "Paused"],
        "menu.pause": [.ja: "一時停止", .en: "Pause"],
        "menu.resume": [.ja: "再開", .en: "Resume"],
        "menu.refresh": [.ja: "今すぐ更新", .en: "Refresh Now"],
        "menu.quit": [.ja: "終了", .en: "Quit"],
        "menu.openDashboard": [.ja: "ダッシュボードを開く", .en: "Open Dashboard"],
        "menu.language": [.ja: "言語", .en: "Language"],
        "menu.pausedHint": [
            .ja: "一時停止中（自動更新なし）",
            .en: "Paused (no automatic refresh)"
        ],
        "menu.authNeeded": [
            .ja: "Cursor のセッションを取得できません。Cursor.app に再ログインするか、cursor.com の Cookie（WorkosCursorSessionToken など）の値だけを貼り付けてください。",
            .en: "Could not read a Cursor session. Re-sign in to Cursor.app, or paste a cursor.com cookie value (e.g. WorkosCursorSessionToken) below."
        ],
        "menu.cookieSection": [.ja: "セッション Cookie", .en: "Session Cookie"],
        "menu.cookieSaved": [
            .ja: "手動 Cookie を保存済み。新しい値を貼ると上書きできます。",
            .en: "A manual cookie is saved. Paste a new value to replace it."
        ],
        "menu.cookieUsingApp": [
            .ja: "Cursor.app のセッションを利用中。必要なら Cookie の値を貼って上書きできます。",
            .en: "Using Cursor.app session. Paste a cookie value below to override."
        ],
        "menu.cookieName": [
            .ja: "WorkosCursorSessionToken=",
            .en: "WorkosCursorSessionToken="
        ],
        "menu.cookiePlaceholder": [
            .ja: "値を貼り付け",
            .en: "Paste value"
        ],
        "menu.saveCookie": [.ja: "保存 / 上書き", .en: "Save / Replace"],
        "menu.clearCookie": [.ja: "削除", .en: "Delete"],
        "menu.lastUpdated": [.ja: "最終更新: %@", .en: "Updated: %@"],
        "menu.teamEmpty": [
            .ja: "Team ID が空です。ターミナルで ./scripts/sync-team.sh を実行してからビルドし直してください。",
            .en: "Team ID is empty. Run ./scripts/sync-team.sh and rebuild."
        ],
        "widget.placeholder": [
            .ja: "メニューバーアプリを起動して使用量を取得してください",
            .en: "Open the menu bar app to fetch usage"
        ],
        "widget.selectProvider": [
            .ja: "プロバイダを選択",
            .en: "Select a provider"
        ],
        "error.unauthorized": [
            .ja: "認証に失敗しました。Cursor に再ログインするか Cookie を更新してください。",
            .en: "Authentication failed. Re-sign in to Cursor or update the cookie."
        ],
        "error.network": [
            .ja: "使用量の取得に失敗しました: %@",
            .en: "Failed to fetch usage: %@"
        ],
        "intent.refresh": [.ja: "更新", .en: "Refresh"],
        "intent.refresh.desc": [
            .ja: "使用量を取り直します。",
            .en: "Fetches the latest usage."
        ],
        "intent.pause": [.ja: "自動更新の停止と再開", .en: "Pause or Resume Auto-Refresh"],
        "intent.pause.desc": [
            .ja: "使用量の自動更新を一時停止、または再開します。",
            .en: "Pauses or resumes automatic usage refresh."
        ],
        "intent.dashboard": [.ja: "ダッシュボードを開く", .en: "Open Dashboard"],
        "intent.dashboard.desc": [
            .ja: "プランと使用量のページをブラウザで開きます。",
            .en: "Opens the plan and usage page in a browser."
        ]
    ]
}
