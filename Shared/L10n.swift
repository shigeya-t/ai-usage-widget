import Foundation

enum L10n {
    static func string(_ key: String, language: AppLanguage = AppSettings.language) -> String {
        table[key]?[language] ?? table[key]?[.en] ?? key
    }

    static func format(_ key: String, _ args: CVarArg..., language: AppLanguage = AppSettings.language) -> String {
        String(format: string(key, language: language), locale: locale(for: language), arguments: args)
    }

    /// App Group 由来のキーは、表にあり `%@` が1つだけのときだけ書式化する。
    /// 未知のキーや数値指定子は `String(format:)` に渡さず、そのまま表示する。
    static func formatKnown(_ key: String, _ arg: String, language: AppLanguage = AppSettings.language) -> String {
        let template = string(key, language: language)
        guard table[key] != nil, isSingleStringTemplate(template) else {
            return template
        }
        return String(format: template, locale: locale(for: language), arg)
    }

    /// `%%` を除き、文字列指定子 `%@`（位置指定 `%1$@` を含む）がちょうど1つ。
    static func isSingleStringTemplate(_ template: String) -> Bool {
        var count = 0
        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "%" else {
                index = template.index(after: index)
                continue
            }
            let next = template.index(after: index)
            if next == template.endIndex { return false }
            if template[next] == "%" {
                index = template.index(after: next)
                continue
            }
            var cursor = next
            if template[cursor].isNumber {
                while cursor < template.endIndex, template[cursor].isNumber {
                    cursor = template.index(after: cursor)
                }
                guard cursor < template.endIndex, template[cursor] == "$" else { return false }
                cursor = template.index(after: cursor)
            }
            guard cursor < template.endIndex, template[cursor] == "@" else { return false }
            count += 1
            if count > 1 { return false }
            index = template.index(after: cursor)
        }
        return count == 1
    }

    static func locale(for language: AppLanguage) -> Locale {
        switch language {
        case .ja: return Locale(identifier: "ja_JP")
        case .en: return Locale(identifier: "en_US")
        }
    }

    private static let table: [String: [AppLanguage: String]] = [
        "provider.cursor": [.ja: "Cursor", .en: "Cursor"],
        "provider.claude": [.ja: "Claude", .en: "Claude"],
        "provider.chatgpt": [.ja: "Codex", .en: "Codex"],
        "menu.provider": [.ja: "サービス", .en: "Service"],
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
        "meter.fiveHour": [.ja: "5時間枠", .en: "5-hour"],
        "meter.fiveHour.subtitle": [.ja: "セッションの利用枠", .en: "Session usage window"],
        "meter.sevenDay": [.ja: "週次枠", .en: "Weekly"],
        "meter.sevenDay.subtitle": [.ja: "すべてのモデル", .en: "All models"],
        "meter.sevenDayOpus": [.ja: "週次 Opus", .en: "Weekly Opus"],
        "meter.sevenDaySonnet": [.ja: "週次 Sonnet", .en: "Weekly Sonnet"],
        "meter.cloudSessionCredit": [.ja: "クラウドセッションクレジット", .en: "Cloud session credits"],
        "meter.cloudSessionCredit.subtitle": [
            .ja: "ワンタイムのセッション枠",
            .en: "One-time session credit"
        ],
        "meter.cloudSessionCredit.expires": [
            .ja: "ワンタイム · %@まで",
            .en: "One-time · expires %@"
        ],
        "spend.cloudSessionCredit": [.ja: "クラウドセッションクレジット", .en: "Cloud session credits"],
        "spend.cloudSessionCredit.compact": [.ja: "クラウドクレジット", .en: "Cloud credits"],
        "spend.cloudSessionCredit.subtitle": [
            .ja: "含まれるクレジット",
            .en: "Included credits"
        ],
        "spend.cloudSessionCredit.expires": [
            .ja: "%@に期限切れ",
            .en: "Expires %@"
        ],
        "spend.remaining": [.ja: "残 $%.0f / $%.0f", .en: "$%.0f left / $%.0f"],
        "spend.remaining.compact": [.ja: "残$%.0f/$%.0f", .en: "$%.0f/$%.0f left"],
        "meter.window.primary": [.ja: "メイン枠", .en: "Primary"],
        "meter.window.secondary": [.ja: "サブ枠", .en: "Secondary"],
        "meter.window.fiveHour": [.ja: "5時間枠", .en: "5-hour"],
        "meter.window.fiveHour.subtitle": [.ja: "短いリセット周期", .en: "Short reset window"],
        "meter.window.daily": [.ja: "日次枠", .en: "Daily"],
        "meter.window.weekly": [.ja: "週次枠", .en: "Weekly"],
        "meter.window.weekly.subtitle": [.ja: "長いリセット周期", .en: "Longer reset window"],
        "meter.window.monthly": [.ja: "月次枠", .en: "Monthly"],
        "meter.codeReview": [.ja: "コードレビュー", .en: "Code Review"],
        "spend.extraUsage": [.ja: "追加クレジット", .en: "Extra usage"],
        "spend.extraUsage.note": [
            .ja: "プラン枠を超えた追加使用です。",
            .en: "Pay-as-you-go usage beyond the plan window."
        ],
        "spend.extraUsage.outOfCredits": [
            .ja: "クレジット残高がなく、追加使用は停止中です。",
            .en: "Usage credits are empty, so extra usage is paused."
        ],
        "spend.credits": [.ja: "クレジット", .en: "Credits"],
        "spend.credits.note": [
            .ja: "Codex の追加クレジット残高です。プラン枠ではありません。",
            .en: "Extra usage-credit balance for Codex, not the plan window."
        ],
        "spend.credits.balance": [.ja: "残高 %@", .en: "%@ credits"],
        "spend.credits.balance.compact": [.ja: "残%@", .en: "%@ cr"],
        "spend.apiCost": [.ja: "API 使用量", .en: "API usage"],
        "spend.apiCost.note": [
            .ja: "公式 Cost API による今月の API 費用です。プラン枠のパーセントではありません。",
            .en: "This month’s API spend from the official Cost API, not a plan-window percent."
        ],
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
        "menu.authNeeded.cursor": [
            .ja: "Cursor のセッションを取得できません。Cursor.app に再ログインするか、cursor.com の Cookie（WorkosCursorSessionToken など）の値だけを貼り付けてください。",
            .en: "Could not read a Cursor session. Re-sign in to Cursor.app, or paste a cursor.com cookie value (e.g. WorkosCursorSessionToken) below."
        ],
        "menu.authNeeded.claude": [
            .ja: "Claude Code のログインが見つかりません。Keychain のダイアログは、Claude Code の項目があるときだけ出ます。Claude.app（デスクトップ）のログインでは出ません。ターミナルで claude を起動して /login するか、access token を貼り付けてください。",
            .en: "No Claude Code login was found. The keychain prompt appears only when a Claude Code item exists. A Claude.app desktop login will not show it. Run claude in the terminal and /login, or paste an OAuth access token."
        ],
        "menu.authNeeded.chatgpt": [
            .ja: "Codex のセッションを取得できません。Codex CLI にログインするか、access token を貼り付けてください。期限切れのときは Codex を一度起動してください（こちらからトークンは更新しません）。",
            .en: "Could not read a Codex session. Sign in to the Codex CLI, or paste an access token. If it expired, open Codex once (this app does not refresh tokens)."
        ],
        "menu.cookieSection": [.ja: "認証", .en: "Authentication"],
        /// エラーは上に赤字で出ている。ここで別の診断を繰り返さない。
        "menu.credentialFallback": [
            .ja: "自動取得に失敗したときは、ここに値を貼り付けてください。",
            .en: "If the automatic pickup fails, paste a value here."
        ],
        "menu.cookieSaved": [
            .ja: "手動 Cookie を保存済み。新しい値を貼ると上書きできます。",
            .en: "A manual cookie is saved. Paste a new value to replace it."
        ],
        "menu.credentialSaved": [
            .ja: "手動の認証情報を保存済み。新しい値を貼ると上書きできます。",
            .en: "A manual credential is saved. Paste a new value to replace it."
        ],
        "menu.cookieUsingApp": [
            .ja: "Cursor.app のセッションを利用中。必要なら Cookie の値を貼って上書きできます。",
            .en: "Using Cursor.app session. Paste a cookie value below to override."
        ],
        "menu.cookieName": [
            .ja: "WorkosCursorSessionToken=",
            .en: "WorkosCursorSessionToken="
        ],
        "menu.credentialName.cursor": [
            .ja: "WorkosCursorSessionToken=",
            .en: "WorkosCursorSessionToken="
        ],
        "menu.credentialName.claude": [
            .ja: "Bearer ",
            .en: "Bearer "
        ],
        "menu.credentialName.chatgpt": [
            .ja: "Bearer ",
            .en: "Bearer "
        ],
        "menu.credentialUsingApp.cursor": [
            .ja: "Cursor.app のセッションを利用中。必要なら Cookie の値を貼って上書きできます。",
            .en: "Using Cursor.app session. Paste a cookie value below to override."
        ],
        "menu.credentialUsingApp.claude": [
            .ja: "Claude Code のセッションを利用中。必要なら access token を貼って上書きできます。",
            .en: "Using the Claude Code session. Paste an access token below to override."
        ],
        "menu.credentialUsingApp.chatgpt": [
            .ja: "Codex CLI のセッションを利用中。必要なら access token を貼って上書きできます。",
            .en: "Using the Codex CLI session. Paste an access token below to override."
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
            .ja: "認証に失敗しました。再ログインするかトークンを更新してください。",
            .en: "Authentication failed. Re-sign in or update the token."
        ],
        "error.unauthorized.cursor": [
            .ja: "認証に失敗しました。Cursor に再ログインするか Cookie を更新してください。",
            .en: "Authentication failed. Re-sign in to Cursor or update the cookie."
        ],
        "error.unauthorized.claude": [
            .ja: "認証に失敗しました。Claude Code に再ログインするか、Admin API キーを更新してください。",
            .en: "Authentication failed. Re-sign in to Claude Code or update the Admin API key."
        ],
        "error.unauthorized.chatgpt": [
            .ja: "認証に失敗しました。Codex に再ログインするか、Admin API キーを更新してください。",
            .en: "Authentication failed. Re-sign in to Codex or update the Admin API key."
        ],
        "error.tokenExpired.cursor": [
            .ja: "Cursor のセッションが期限切れです。Cursor.app を一度起動してから「更新」を押してください。",
            .en: "The Cursor session expired. Open Cursor.app once, then press Refresh."
        ],
        "error.tokenExpired.claude": [
            .ja: "Claude Code のトークンが期限切れです。ターミナルで claude を一度起動してから「更新」を押してください（このアプリはトークンを更新しません）。",
            .en: "The Claude Code token expired. Run claude in the terminal once, then press Refresh (this app does not refresh tokens)."
        ],
        "error.tokenExpired.chatgpt": [
            .ja: "Codex のトークンが期限切れです。Codex を一度起動してから「更新」を押してください（このアプリはトークンを更新しません）。",
            .en: "The Codex token expired. Open Codex once, then press Refresh (this app does not refresh tokens)."
        ],
        "error.rateLimited": [
            .ja: "使用量 API が混雑しています。しばらく待ってから更新してください。",
            .en: "The usage API is rate-limited. Wait a bit, then refresh."
        ],
        "error.apiKeyMode.claude": [
            .ja: "Claude のプラン枠は Claude Code のアカウントログインで取れます。API 消費は公式 Cost API 用の Admin キー（sk-ant-admin01- など）が必要です。",
            .en: "Claude plan windows need a Claude Code account login. API spend needs an Admin key for the official Cost API (e.g. sk-ant-admin01-)."
        ],
        "error.keychainDenied.claude": [
            .ja: "Claude Code の Keychain を拒否されたか、このアプリからは読めません。ダイアログが出たら「常に許可」を選んでください。Claude.app のログインは代わりになりません。",
            .en: "Claude Code keychain access was denied or is unreadable by this app. If a prompt appears, choose Always Allow. A Claude.app desktop login cannot be used instead."
        ],
        "error.apiKeyMode.chatgpt": [
            .ja: "Codex の利用枠は ChatGPT アカウントでログインした Codex CLI から取れます。API 消費は公式 Cost API 用の Admin キーが必要です。",
            .en: "Codex plan windows need a Codex CLI login with a ChatGPT account. API spend needs an Admin key for the official Cost API."
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
