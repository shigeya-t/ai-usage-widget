import Foundation

struct CursorProvider: UsageProvider {
    static let id = "cursor"

    var id: String { Self.id }
    var displayNameKey: String { "provider.cursor" }
    var dashboardURL: URL { URL(string: "https://cursor.com/dashboard?tab=usage")! }
    var credentialNameKey: String { "menu.credentialName.cursor" }
    var authNeededKey: String { "menu.authNeeded.cursor" }
    var usingAppKey: String { "menu.credentialUsingApp.cursor" }

    func loadManualCredential() -> String? { CursorSession.loadManualCookie() }
    func saveManualCredential(_ raw: String) throws { try CursorSession.saveManualCookie(raw) }
    func clearManualCredential() { CursorSession.clearManualCookie() }

    private static let knownPrices: [String: String] = [
        "free": "$0",
        "pro": "$20/mo",
        "pro_plus": "$60/mo",
        "pro+": "$60/mo",
        "ultra": "$200/mo",
        "business": "Business",
        "enterprise": "Enterprise",
        "hobby": "Hobby"
    ]

    func fetchSnapshot() async throws -> UsageSnapshot {
        let cookie = try CursorSession.resolveCookieValue()
        let summary = try await Self.fetchUsageSummary(cookie: cookie)
        var account: String?
        if let me = try? await Self.fetchAuthMe(cookie: cookie) {
            account = me.email ?? me.name
        }
        var snap = Self.mapSummary(summary, accountLabel: account, fetchedAt: Date())
        if let grok = try? await Self.fetchGrokMeter(cookie: cookie) {
            snap.meters.append(grok)
        }
        return snap
    }

    // MARK: - Network

    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static func fetchUsageSummary(cookie: String) async throws -> UsageSummaryResponse {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CursorAPIError.unauthorized
        }
        if http.statusCode == 429 {
            throw CursorAPIError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CursorAPIError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(UsageSummaryResponse.self, from: data)
        } catch {
            usageLogger.error("usage-summary decode failed: \(String(describing: error), privacy: .public)")
            throw CursorAPIError.decodeFailed
        }
    }

    private static func fetchAuthMe(cookie: String) async throws -> AuthMeResponse {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/auth/me")!)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CursorAPIError.unauthorized
        }
        return try JSONDecoder().decode(AuthMeResponse.self, from: data)
    }

    /// Grok Bot 週次枠。失敗・枠なしなら nil。
    static func fetchGrokMeter(cookie: String) async throws -> UsageMeter? {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!)
        request.httpMethod = "POST"
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let status = try JSONDecoder().decode(SandUsageStatusResponse.self, from: data)
        guard let percent = status.usagePercent else { return nil }
        // 枠ゼロのアカウントは出さない
        if percent == 0, status.nextResetTimestampUtc == nil { return nil }
        return UsageMeter(
            id: "grok-bot",
            titleKey: "meter.grokBot",
            subtitleKey: "meter.grokBot.subtitle",
            percentUsed: percent,
            accent: .secondary
        )
    }

    // MARK: - Mapping

    static func mapSummary(
        _ summary: UsageSummaryResponse,
        accountLabel: String?,
        fetchedAt: Date
    ) -> UsageSnapshot {
        let membership = summary.membershipType ?? "unknown"
        let planName = displayPlanName(membership)
        let price = knownPrices[membership.lowercased()]

        let autoPercent = resolvePercent(
            preferred: summary.individualUsage?.plan?.autoPercentUsed,
            message: summary.autoModelSelectedDisplayMessage
        )
        let apiPercent = resolvePercent(
            preferred: summary.individualUsage?.plan?.apiPercentUsed,
            message: summary.namedModelSelectedDisplayMessage
        )

        let meters: [UsageMeter] = [
            UsageMeter(
                id: "cursor-models",
                titleKey: "meter.cursorModels",
                subtitleKey: "meter.cursorModels.subtitle",
                percentUsed: autoPercent ?? 0,
                accent: .primary,
                noteKey: "meter.cursorNote"
            ),
            UsageMeter(
                id: "other-models",
                titleKey: "meter.otherModels",
                subtitleKey: nil,
                percentUsed: apiPercent ?? 0,
                accent: .secondary,
                noteKey: "meter.otherNote"
            )
        ]

        let spend = mapSpend(summary)

        let resetAt = DateParsing.iso8601(summary.billingCycleEnd)

        return UsageSnapshot(
            providerID: id,
            accountLabel: accountLabel,
            plan: PlanInfo(name: planName, priceText: price, resetAt: resetAt),
            meters: meters,
            spend: spend,
            fetchedAt: fetchedAt,
            errorMessage: nil
        )
    }

    private static func mapSpend(_ summary: UsageSummaryResponse) -> SpendMeter? {
        let individual = summary.individualUsage?.onDemand
        let team = summary.teamUsage?.onDemand

        // 個人のオンデマンドを優先。無効ならチーム枠を見る。
        let source: OnDemandUsage?
        if let individual, individual.enabled != false {
            source = individual
        } else if let team, team.enabled != false {
            source = team
        } else {
            source = individual ?? team
        }
        guard let source else { return nil }

        let usedCents = source.used ?? 0
        let limitCents = source.limit
        let isUnlimited = limitCents == nil

        let limitUSD: Double? = limitCents.map { Double($0) / 100.0 }

        return SpendMeter(
            id: "on-demand",
            titleKey: "spend.onDemand",
            noteKey: "spend.onDemand.note",
            usedUSD: Double(usedCents) / 100.0,
            limitUSD: limitUSD,
            isUnlimited: isUnlimited
        )
    }

    static func displayPlanName(_ membership: String) -> String {
        switch membership.lowercased() {
        case "pro": return "Pro"
        case "pro_plus", "pro+": return "Pro+"
        case "ultra": return "Ultra"
        case "free": return "Free"
        case "hobby": return "Hobby"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        default:
            if membership.isEmpty { return "—" }
            return membership.prefix(1).uppercased() + membership.dropFirst().lowercased()
        }
    }

    static func resolvePercent(preferred: Double?, message: String?) -> Double? {
        if let preferred { return preferred }
        return parsePercent(from: message)
    }

    /// "You've used 42% of your included total usage" などからパーセントを取る。
    static func parsePercent(from message: String?) -> Double? {
        guard let message, !message.isEmpty else { return nil }
        let pattern = #"(\d+(?:\.\d+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              let percentRange = Range(match.range(at: 1), in: message)
        else { return nil }
        return Double(message[percentRange])
    }
}

// MARK: - Wire types

struct UsageSummaryResponse: Codable, Equatable {
    var billingCycleStart: String?
    var billingCycleEnd: String?
    var membershipType: String?
    var limitType: String?
    var isUnlimited: Bool?
    var autoModelSelectedDisplayMessage: String?
    var namedModelSelectedDisplayMessage: String?
    var individualUsage: IndividualUsage?
    var teamUsage: TeamUsage?
}

struct IndividualUsage: Codable, Equatable {
    var plan: PlanUsage?
    var onDemand: OnDemandUsage?
}

struct PlanUsage: Codable, Equatable {
    var enabled: Bool?
    var used: Double?
    var limit: Double?
    var remaining: Double?
    var breakdown: PlanBreakdown?
    var autoPercentUsed: Double?
    var apiPercentUsed: Double?
    var totalPercentUsed: Double?
}

struct PlanBreakdown: Codable, Equatable {
    var included: Double?
    var bonus: Double?
    var total: Double?
}

struct OnDemandUsage: Codable, Equatable {
    var enabled: Bool?
    var used: Double?
    var limit: Double?
    var remaining: Double?
}

struct TeamUsage: Codable, Equatable {
    var onDemand: OnDemandUsage?
}

struct AuthMeResponse: Codable {
    var email: String?
    var name: String?
    var id: Int?
    var sub: String?
}

struct SandUsageStatusResponse: Codable, Equatable {
    var usagePercent: Double?
    var nextResetTimestampUtc: String?
}
