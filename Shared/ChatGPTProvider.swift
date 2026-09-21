import Foundation

struct ChatGPTProvider: UsageProvider {
    static let id = "chatgpt"

    var id: String { Self.id }
    var displayNameKey: String { "provider.chatgpt" }
    var dashboardURL: URL { URL(string: "https://chatgpt.com/codex")! }
    var credentialNameKey: String { "menu.credentialName.chatgpt" }
    var authNeededKey: String { "menu.authNeeded.chatgpt" }
    var usingAppKey: String { "menu.credentialUsingApp.chatgpt" }

    func hasAnyCredential() -> Bool { ChatGPTSession.hasAnyCredential() }
    func loadManualCredential() -> String? { ChatGPTSession.loadManualToken() }
    func saveManualCredential(_ raw: String) throws { try ChatGPTSession.saveManualToken(raw) }
    func clearManualCredential() { ChatGPTSession.clearManualToken() }

    func fetchSnapshot() async throws -> UsageSnapshot {
        switch try ChatGPTSession.resolveCredential() {
        case .apiKey(let apiKey):
            return try await Self.fetchOfficialSnapshot(apiKey: apiKey)
        case .chatgpt(let auth):
            let usage = try await Self.fetchUsage(auth: auth)
            return Self.mapUsage(
                usage,
                accountLabel: auth.email,
                fallbackPlanType: auth.planType,
                fetchedAt: Date()
            )
        }
    }

    // MARK: - Network

    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static func fetchUsage(auth: ChatGPTAuth) async throws -> ChatGPTUsageResponse {
        let urls = [
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            URL(string: "https://chatgpt.com/backend-api/codex/usage")!
        ]
        var lastError: Error = UsageAPIError.decodeFailed
        for url in urls {
            do {
                return try await fetchUsage(url: url, auth: auth)
            } catch UsageAPIError.httpStatus(let code) where code == 404 {
                lastError = UsageAPIError.httpStatus(code)
                continue
            } catch {
                throw error
            }
        }
        throw lastError
    }

    private static func fetchUsage(url: URL, auth: ChatGPTAuth) async throws -> ChatGPTUsageResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = auth.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/codex", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")

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
            return try JSONDecoder().decode(ChatGPTUsageResponse.self, from: data)
        } catch {
            usageLogger.error("chatgpt usage decode failed: \(String(describing: error), privacy: .public)")
            throw UsageAPIError.decodeFailed
        }
    }

    static func fetchOfficialSnapshot(apiKey: String, now: Date = Date()) async throws -> UsageSnapshot {
        let month = DateParsing.utcMonthBounds(containing: now)
        let costs = try await fetchCosts(apiKey: apiKey, start: month.start)
        return mapCosts(costs, monthEnd: month.end, fetchedAt: now)
    }

    private static func fetchCosts(apiKey: String, start: Date) async throws -> OpenAICostsResponse {
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31")
        ]
        guard let url = components.url else { throw UsageAPIError.decodeFailed }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsageWidget/1.1", forHTTPHeaderField: "User-Agent")

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
            return try JSONDecoder().decode(OpenAICostsResponse.self, from: data)
        } catch {
            usageLogger.error("openai costs decode failed: \(String(describing: error), privacy: .public)")
            throw UsageAPIError.decodeFailed
        }
    }

    // MARK: - Mapping

    static func mapUsage(
        _ usage: ChatGPTUsageResponse,
        accountLabel: String?,
        fallbackPlanType: String?,
        fetchedAt: Date
    ) -> UsageSnapshot {
        let details = preferredRateLimit(usage)
        var meters: [UsageMeter] = []
        if let primary = details?.primaryWindow {
            meters.append(windowMeter(id: "primary", window: primary, fallbackTitleKey: "meter.window.primary", accent: .primary))
        }
        if let secondary = details?.secondaryWindow {
            meters.append(windowMeter(id: "secondary", window: secondary, fallbackTitleKey: "meter.window.secondary", accent: .secondary))
        }
        if let review = usage.codeReviewRateLimit?.primaryWindow ?? usage.codeReviewRateLimit?.secondaryWindow {
            meters.append(
                windowMeter(
                    id: "code-review",
                    window: review,
                    fallbackTitleKey: "meter.codeReview",
                    accent: .secondary
                )
            )
        }

        let spend: SpendMeter? = nil
        let resetAt = details?.primaryWindow?.resetAt?.date
            ?? details?.secondaryWindow?.resetAt?.date
        let planType = usage.planType ?? fallbackPlanType

        return UsageSnapshot(
            providerID: Self.id,
            accountLabel: accountLabel,
            plan: PlanInfo(
                name: displayPlanName(planType),
                priceText: knownPrice(planType),
                resetAt: resetAt
            ),
            meters: meters,
            spend: spend,
            fetchedAt: fetchedAt,
            errorMessage: nil
        )
    }

    static func preferredRateLimit(_ usage: ChatGPTUsageResponse) -> ChatGPTRateLimitDetails? {
        if let additional = usage.additionalRateLimits {
            if let codex = additional.first(where: { $0.isCodex }), let details = codex.rateLimit {
                return details
            }
        }
        return usage.rateLimit
    }

    static func windowTitleKey(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "meter.window.primary" }
        if abs(seconds - 18_000) < 1_800 { return "meter.window.fiveHour" }
        if abs(seconds - 86_400) < 3_600 { return "meter.window.daily" }
        if abs(seconds - 604_800) < 86_400 { return "meter.window.weekly" }
        if abs(seconds - 2_592_000) < 259_200 { return "meter.window.monthly" }
        return "meter.window.primary"
    }

    static func displayPlanName(_ membership: String?) -> String {
        switch (membership ?? "").lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite", "pro_lite": return "Pro Lite"
        case "free", "guest", "go": return "Free"
        case "team", "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        case "": return "ChatGPT"
        default:
            let raw = membership ?? ""
            return raw.split(separator: "_").map { part in
                part.prefix(1).uppercased() + part.dropFirst().lowercased()
            }.joined(separator: " ")
        }
    }

    static func knownPrice(_ membership: String?) -> String? {
        switch (membership ?? "").lowercased() {
        case "plus": return "$20/mo"
        case "pro": return "$200/mo"
        case "prolite", "pro_lite": return "Pro Lite"
        default: return nil
        }
    }

    static func mapCosts(
        _ costs: OpenAICostsResponse,
        monthEnd: Date,
        fetchedAt: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            providerID: Self.id,
            accountLabel: nil,
            plan: PlanInfo(name: "API", priceText: nil, resetAt: monthEnd),
            meters: [],
            spend: SpendMeter(
                id: "api-cost",
                titleKey: "spend.apiCost",
                noteKey: "spend.apiCost.note",
                usedUSD: costs.totalUSD,
                limitUSD: nil,
                isUnlimited: true
            ),
            fetchedAt: fetchedAt,
            errorMessage: nil
        )
    }

    private static func windowMeter(
        id: String,
        window: ChatGPTRateLimitWindow,
        fallbackTitleKey: String,
        accent: UsageMeter.MeterAccent
    ) -> UsageMeter {
        let seconds = window.limitWindowSeconds?.value
        let titleKey: String
        if id == "code-review" {
            titleKey = fallbackTitleKey
        } else {
            let fromWindow = windowTitleKey(seconds: seconds)
            titleKey = fromWindow == "meter.window.primary" ? fallbackTitleKey : fromWindow
        }
        return UsageMeter(
            id: id,
            titleKey: titleKey,
            subtitleKey: subtitleKey(seconds: seconds),
            percentUsed: window.usedPercent?.value ?? 0,
            accent: accent
        )
    }

    private static func subtitleKey(seconds: Double?) -> String? {
        switch windowTitleKey(seconds: seconds) {
        case "meter.window.fiveHour": return "meter.window.fiveHour.subtitle"
        case "meter.window.weekly": return "meter.window.weekly.subtitle"
        default: return nil
        }
    }
}

// MARK: - Wire types

struct ChatGPTUsageResponse: Codable, Equatable {
    var planType: String?
    var rateLimit: ChatGPTRateLimitDetails?
    var additionalRateLimits: [ChatGPTAdditionalRateLimit]?
    var codeReviewRateLimit: ChatGPTRateLimitDetails?
    var credits: ChatGPTCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case codeReviewRateLimit = "code_review_rate_limit"
        case credits
    }
}

struct ChatGPTRateLimitDetails: Codable, Equatable {
    var primaryWindow: ChatGPTRateLimitWindow?
    var secondaryWindow: ChatGPTRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct ChatGPTRateLimitWindow: Codable, Equatable {
    var usedPercent: JSONNumber?
    var limitWindowSeconds: JSONNumber?
    var resetAt: JSONTimestamp?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}

struct ChatGPTAdditionalRateLimit: Codable, Equatable {
    var limitName: String?
    var meteredFeature: String?
    var limitId: String?
    var rateLimit: ChatGPTRateLimitDetails?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case limitId = "limit_id"
        case rateLimit = "rate_limit"
    }

    var isCodex: Bool {
        let names = [limitName, meteredFeature, limitId]
            .compactMap { $0?.lowercased() }
        return names.contains { $0 == "codex" || $0.hasPrefix("codex") }
    }
}

struct ChatGPTCredits: Codable, Equatable {
    var hasCredits: Bool?
    var unlimited: Bool?
    var balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

struct OpenAICostsResponse: Codable, Equatable {
    var data: [OpenAICostBucket]?

    var totalUSD: Double {
        (data ?? []).reduce(0) { partial, bucket in
            partial + (bucket.results ?? []).reduce(0) { $0 + ($1.amount?.value?.value ?? 0) }
        }
    }
}

struct OpenAICostBucket: Codable, Equatable {
    var startTime: JSONNumber?
    var endTime: JSONNumber?
    var results: [OpenAICostResult]?

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

struct OpenAICostResult: Codable, Equatable {
    var amount: OpenAICostAmount?
}

struct OpenAICostAmount: Codable, Equatable {
    var value: JSONNumber?
    var currency: String?
}
