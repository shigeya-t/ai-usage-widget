import Foundation

struct ClaudeProvider: UsageProvider {
    static let id = "claude"

    var id: String { Self.id }
    var displayNameKey: String { "provider.claude" }
    var dashboardURL: URL { URL(string: "https://claude.ai/settings/usage")! }
    var credentialNameKey: String { "menu.credentialName.claude" }
    var authNeededKey: String { "menu.authNeeded.claude" }
    var usingAppKey: String { "menu.credentialUsingApp.claude" }

    func loadManualCredential() -> String? { ClaudeSession.loadManualToken() }
    func saveManualCredential(_ raw: String) throws { try ClaudeSession.saveManualToken(raw) }
    func clearManualCredential() { ClaudeSession.clearManualToken() }

    func fetchSnapshot() async throws -> UsageSnapshot {
        let credential = try await ClaudeSession.resolveCredential()
        switch credential {
        case .apiKey(let apiKey):
            return try await Self.fetchOfficialSnapshot(apiKey: apiKey)
        case .oauth(let creds):
            let usage = try await Self.fetchUsage(accessToken: creds.accessToken)
            var account = creds.email
            if account == nil, let profile = try? await Self.fetchProfile(accessToken: creds.accessToken) {
                account = profile.email
            }
            return Self.mapUsage(
                usage,
                accountLabel: account,
                subscriptionType: creds.subscriptionType,
                rateLimitTier: creds.rateLimitTier,
                fetchedAt: Date()
            )
        }
    }

    // MARK: - Network

    private static let userAgent = "AIUsageWidget/1.1"

    static func fetchUsage(accessToken: String) async throws -> ClaudeOAuthUsageResponse {
        try await fetchJSON(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            accessToken: accessToken
        )
    }

    private static func fetchProfile(accessToken: String) async throws -> ClaudeOAuthProfileResponse {
        try await fetchJSON(
            url: URL(string: "https://api.anthropic.com/api/oauth/profile")!,
            accessToken: accessToken
        )
    }

    private static func fetchJSON<T: Decodable>(url: URL, accessToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageAPIError.unauthorized
        }
        if http.statusCode == 429 {
            throw UsageAPIError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageAPIError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            usageLogger.error("claude usage decode failed: \(String(describing: error), privacy: .public)")
            throw UsageAPIError.decodeFailed
        }
    }

    static func fetchOfficialSnapshot(apiKey: String, now: Date = Date()) async throws -> UsageSnapshot {
        let month = DateParsing.utcMonthBounds(containing: now)
        let report = try await fetchCostReport(apiKey: apiKey, start: month.start, end: month.end)
        return mapCostReport(report, monthEnd: month.end, fetchedAt: now)
    }

    private static func fetchCostReport(apiKey: String, start: Date, end: Date) async throws -> ClaudeCostReportResponse {
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: DateParsing.rfc3339(start)),
            URLQueryItem(name: "ending_at", value: DateParsing.rfc3339(end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31")
        ]
        guard let url = components.url else { throw UsageAPIError.decodeFailed }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageAPIError.unauthorized
        }
        if http.statusCode == 429 {
            throw UsageAPIError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageAPIError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(ClaudeCostReportResponse.self, from: data)
        } catch {
            usageLogger.error("claude cost_report decode failed: \(String(describing: error), privacy: .public)")
            throw UsageAPIError.decodeFailed
        }
    }

    // MARK: - Mapping

    static func mapUsage(
        _ usage: ClaudeOAuthUsageResponse,
        accountLabel: String?,
        subscriptionType: String?,
        rateLimitTier: String?,
        fetchedAt: Date
    ) -> UsageSnapshot {
        var meters: [UsageMeter] = []
        if let window = usage.fiveHour {
            meters.append(meter(id: "five-hour", titleKey: "meter.fiveHour", subtitleKey: "meter.fiveHour.subtitle", window: window, accent: .primary))
        }
        if let window = usage.sevenDay {
            meters.append(meter(id: "seven-day", titleKey: "meter.sevenDay", subtitleKey: "meter.sevenDay.subtitle", window: window, accent: .secondary))
        }
        if let window = usage.sevenDayOpus {
            meters.append(meter(id: "seven-day-opus", titleKey: "meter.sevenDayOpus", subtitleKey: nil, window: window, accent: .secondary))
        }
        if let window = usage.sevenDaySonnet {
            meters.append(meter(id: "seven-day-sonnet", titleKey: "meter.sevenDaySonnet", subtitleKey: nil, window: window, accent: .secondary))
        }

        let spend = mapExtraUsageSpend(usage)

        let resetAt = usage.fiveHour?.resetsAt?.date ?? usage.sevenDay?.resetsAt?.date
        return UsageSnapshot(
            providerID: Self.id,
            accountLabel: accountLabel,
            plan: PlanInfo(
                name: displayPlanName(subscriptionType),
                priceText: knownPrice(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier),
                resetAt: resetAt
            ),
            meters: meters,
            spend: spend,
            fetchedAt: fetchedAt,
            errorMessage: nil
        )
    }

    private static func meter(
        id: String,
        titleKey: String,
        subtitleKey: String?,
        window: ClaudeUsageWindow,
        accent: UsageMeter.MeterAccent
    ) -> UsageMeter {
        UsageMeter(
            id: id,
            titleKey: titleKey,
            subtitleKey: subtitleKey,
            percentUsed: window.utilization?.value ?? 0,
            accent: accent
        )
    }

    static func displayPlanName(_ membership: String?) -> String {
        switch (membership ?? "").lowercased() {
        case "pro", "claude_pro": return "Pro"
        case "max", "claude_max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        case "": return "Claude"
        default:
            let raw = membership ?? ""
            return raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
        }
    }

    static func knownPrice(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let tier = (rateLimitTier ?? "").lowercased()
        if tier.contains("20x") { return "$200/mo" }
        if tier.contains("5x") { return "$100/mo" }
        switch (subscriptionType ?? "").lowercased() {
        case "pro", "claude_pro": return "$20/mo"
        case "max", "claude_max": return "Max"
        default: return nil
        }
    }

    static func mapCostReport(
        _ report: ClaudeCostReportResponse,
        monthEnd: Date,
        fetchedAt: Date
    ) -> UsageSnapshot {
        let usedUSD = report.totalUSD
        return UsageSnapshot(
            providerID: Self.id,
            accountLabel: nil,
            plan: PlanInfo(name: "API", priceText: nil, resetAt: monthEnd),
            meters: [],
            spend: SpendMeter(
                id: "api-cost",
                titleKey: "spend.apiCost",
                noteKey: "spend.apiCost.note",
                usedUSD: usedUSD,
                limitUSD: nil,
                isUnlimited: true
            ),
            fetchedAt: fetchedAt,
            errorMessage: nil
        )
    }

    /// Anthropic Cost API の amount はセント単位の小数文字列（"123.45" = $1.23）。
    static func usdFromCentsString(_ raw: String?) -> Double {
        guard let raw, let cents = Double(raw) else { return 0 }
        return cents / 100.0
    }

    /// OAuth の現行 `spend`（minor + exponent）を優先し、無いときだけ legacy `extra_usage`。
    /// `is_enabled == false` でも残高切れで使った分は出す。未購入アカウントは出さない。
    static func mapExtraUsageSpend(_ usage: ClaudeOAuthUsageResponse) -> SpendMeter? {
        if let spend = usage.spend, let meter = spendMeter(from: spend) {
            return meter
        }
        return spendMeter(from: usage.extraUsage)
    }

    static func usdFromMinor(_ amount: Double?, decimalPlaces: Int?) -> Double? {
        guard let amount else { return nil }
        let places = max(decimalPlaces ?? 0, 0)
        let usd = amount / pow(10.0, Double(places))
        guard usd.isFinite else { return nil }
        return usd
    }

    private static func spendMeter(from spend: ClaudeOAuthSpend) -> SpendMeter? {
        let used = usd(from: spend.used) ?? 0
        let limit = usd(from: spend.limit)
        guard shouldShowExtraUsage(
            enabled: spend.enabled,
            used: used,
            everEnabled: nil,
            disabledReason: spend.disabledReason
        ) else { return nil }
        return extraUsageMeter(used: used, limit: limit, disabledReason: spend.disabledReason)
    }

    private static func spendMeter(from extra: ClaudeExtraUsage?) -> SpendMeter? {
        guard let extra else { return nil }
        let places = extra.decimalPlaces.map { Int($0.value.rounded()) }
        let used = usdFromMinor(extra.usedCredits?.value, decimalPlaces: places) ?? 0
        let limit = usdFromMinor(extra.monthlyLimit?.value, decimalPlaces: places)
        guard shouldShowExtraUsage(
            enabled: extra.isEnabled,
            used: used,
            everEnabled: extra.creditsEverEnabled,
            disabledReason: extra.disabledReason
        ) else { return nil }
        return extraUsageMeter(used: used, limit: limit, disabledReason: extra.disabledReason)
    }

    private static func extraUsageMeter(used: Double, limit: Double?, disabledReason: String?) -> SpendMeter {
        let outOfCredits = disabledReason == "out_of_credits"
        return SpendMeter(
            id: "extra-usage",
            titleKey: "spend.extraUsage",
            noteKey: outOfCredits ? "spend.extraUsage.outOfCredits" : "spend.extraUsage.note",
            usedUSD: used,
            limitUSD: limit,
            isUnlimited: limit == nil
        )
    }

    static func shouldShowExtraUsage(
        enabled: Bool?,
        used: Double,
        everEnabled: Bool?,
        disabledReason: String?
    ) -> Bool {
        if enabled == true { return true }
        if everEnabled == true { return true }
        if used > 0 { return true }
        if disabledReason != nil { return true }
        return false
    }

    private static func usd(from amount: ClaudeMoneyAmount?) -> Double? {
        guard let amount else { return nil }
        let exponent = amount.exponent.map { Int($0.value.rounded()) } ?? 2
        return usdFromMinor(amount.amountMinor?.value, decimalPlaces: exponent)
    }
}

// MARK: - Wire types

struct ClaudeOAuthUsageResponse: Codable, Equatable {
    var fiveHour: ClaudeUsageWindow?
    var sevenDay: ClaudeUsageWindow?
    var sevenDayOpus: ClaudeUsageWindow?
    var sevenDaySonnet: ClaudeUsageWindow?
    var extraUsage: ClaudeExtraUsage?
    var spend: ClaudeOAuthSpend?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case spend
    }
}

struct ClaudeOAuthSpend: Codable, Equatable {
    var used: ClaudeMoneyAmount?
    var limit: ClaudeMoneyAmount?
    var enabled: Bool?
    var disabledReason: String?

    enum CodingKeys: String, CodingKey {
        case used
        case limit
        case enabled
        case disabledReason = "disabled_reason"
    }
}

struct ClaudeMoneyAmount: Codable, Equatable {
    var amountMinor: JSONNumber?
    var currency: String?
    var exponent: JSONNumber?

    enum CodingKeys: String, CodingKey {
        case amountMinor = "amount_minor"
        case currency
        case exponent
    }
}

struct ClaudeUsageWindow: Codable, Equatable {
    var utilization: JSONNumber?
    var resetsAt: JSONTimestamp?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ClaudeExtraUsage: Codable, Equatable {
    var isEnabled: Bool?
    var monthlyLimit: JSONNumber?
    var usedCredits: JSONNumber?
    var utilization: JSONNumber?
    var decimalPlaces: JSONNumber?
    var creditsEverEnabled: Bool?
    var disabledReason: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case decimalPlaces = "decimal_places"
        case creditsEverEnabled = "credits_ever_enabled"
        case disabledReason = "disabled_reason"
    }
}

struct ClaudeOAuthProfileResponse: Codable {
    var account: ClaudeProfileAccount?
    var emailDirect: String?

    enum CodingKeys: String, CodingKey {
        case account
        case emailDirect = "email"
    }

    var email: String? { account?.email ?? emailDirect }
}

struct ClaudeProfileAccount: Codable {
    var email: String?
}

struct ClaudeCostReportResponse: Codable, Equatable {
    var data: [ClaudeCostBucket]?

    var totalUSD: Double {
        (data ?? []).reduce(0) { partial, bucket in
            partial + (bucket.results ?? []).reduce(0) { $0 + ClaudeProvider.usdFromCentsString($1.amount) }
        }
    }
}

struct ClaudeCostBucket: Codable, Equatable {
    var startingAt: String?
    var endingAt: String?
    var results: [ClaudeCostResult]?

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

struct ClaudeCostResult: Codable, Equatable {
    var amount: String?
    var currency: String?
}
