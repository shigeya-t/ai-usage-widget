import XCTest

final class CursorProviderMappingTests: XCTestCase {
    func testMapsProScreenshotLikeSummary() throws {
        let summary = try decodeFixture("usage_summary_pro")
        let snap = CursorProvider.mapSummary(summary, accountLabel: "user@example.com", fetchedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(snap.providerID, "cursor")
        XCTAssertEqual(snap.plan.name, "Pro")
        XCTAssertEqual(snap.plan.priceText, "$20/mo")
        XCTAssertEqual(snap.accountLabel, "user@example.com")
        XCTAssertNotNil(snap.plan.resetAt)

        XCTAssertEqual(snap.meters.count, 2)
        XCTAssertEqual(snap.meters[0].percentUsed, 100)
        XCTAssertEqual(snap.meters[1].percentUsed, 100)
        XCTAssertEqual(snap.meters[0].titleKey, "meter.cursorModels")
        XCTAssertEqual(snap.meters[1].titleKey, "meter.otherModels")
        XCTAssertEqual(snap.meters[0].noteKey, "meter.cursorNote")
        XCTAssertEqual(snap.meters[1].noteKey, "meter.otherNote")

        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.usedUSD, 42.85, accuracy: 0.001)
        XCTAssertEqual(spend.limitUSD ?? -1, 50, accuracy: 0.001)
        XCTAssertFalse(spend.isUnlimited)
        XCTAssertEqual(spend.fraction, 42.85 / 50.0, accuracy: 0.001)
    }

    func testFallsBackToDisplayMessagesAndTeamOnDemand() throws {
        let summary = try decodeFixture("usage_summary_team_fallback")
        let snap = CursorProvider.mapSummary(summary, accountLabel: nil, fetchedAt: Date())

        XCTAssertEqual(snap.plan.name, "Enterprise")
        XCTAssertEqual(snap.meters[0].percentUsed, 42)
        XCTAssertEqual(snap.meters[1].percentUsed, 7)

        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.usedUSD, 12.0, accuracy: 0.001)
        XCTAssertEqual(spend.limitUSD ?? -1, 100.0, accuracy: 0.001)
    }

    func testUnlimitedOnDemand() throws {
        let summary = try decodeFixture("usage_summary_unlimited_ondemand")
        let snap = CursorProvider.mapSummary(summary, accountLabel: nil, fetchedAt: Date())

        XCTAssertEqual(snap.plan.name, "Ultra")
        XCTAssertEqual(snap.meters[0].percentUsed, 12.4, accuracy: 0.01)
        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.usedUSD, 8.5, accuracy: 0.001)
        XCTAssertNil(spend.limitUSD)
        XCTAssertTrue(spend.isUnlimited)
    }

    func testParsePercentFromMessage() {
        XCTAssertEqual(CursorProvider.parsePercent(from: "You've used 42% of your included total usage"), 42)
        XCTAssertEqual(CursorProvider.parsePercent(from: "You've used 6.9% of your included API usage"), 6.9)
        XCTAssertNil(CursorProvider.parsePercent(from: "no percent here"))
        XCTAssertNil(CursorProvider.parsePercent(from: nil))
    }

    func testDisplayPercentMatchesDashboardSmallUsage() {
        XCTAssertEqual(UsageFormatting.displayPercent(0), 0)
        XCTAssertEqual(UsageFormatting.displayPercent(0.37), 1)
        XCTAssertEqual(UsageFormatting.displayPercent(0.9), 1)
        XCTAssertEqual(UsageFormatting.displayPercent(1.0), 1)
        XCTAssertEqual(UsageFormatting.displayPercent(1.4), 1)
        XCTAssertEqual(UsageFormatting.displayPercent(1.5), 2)
        XCTAssertEqual(UsageFormatting.displayPercent(98.1), 98)
        XCTAssertEqual(UsageFormatting.displayPercent(100), 100)
    }

    private func decodeFixture(_ name: String) throws -> UsageSummaryResponse {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(UsageSummaryResponse.self, from: data)
    }
}

final class CursorSessionTests: XCTestCase {
    func testNormalizeBareJWTAttachesSubject() throws {
        // header.payload.sig — payload = {"sub":"user_01TEST","exp":9999999999}
        let payloadJSON = #"{"sub":"user_01TEST","exp":9999999999}"#
        let payload = Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJub25lIn0.\(payload).sig"
        let cookie = CursorSession.normalizeCookieValue(jwt)
        XCTAssertEqual(cookie, "user_01TEST%3A%3A\(jwt)")
        let parts = try CursorSession.parseCookieParts(cookie)
        XCTAssertEqual(parts.userID, "user_01TEST")
        XCTAssertEqual(parts.jwt, jwt)
    }

    func testNormalizeBareJWTStripsAuth0Prefix() throws {
        let payloadJSON = #"{"sub":"auth0|user_01TEST","exp":9999999999}"#
        let payload = Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJub25lIn0.\(payload).sig"
        let cookie = CursorSession.normalizeCookieValue(jwt)
        XCTAssertEqual(cookie, "user_01TEST%3A%3A\(jwt)")
    }

    func testCookieUserIDFromAuth0Subject() throws {
        XCTAssertEqual(
            try CursorSession.cookieUserID(fromJWTSubject: "auth0|user_01ABC"),
            "user_01ABC"
        )
        XCTAssertEqual(
            try CursorSession.cookieUserID(fromJWTSubject: "auth0%7Cuser_01ABC"),
            "user_01ABC"
        )
        XCTAssertEqual(
            try CursorSession.cookieUserID(fromJWTSubject: "user_01ABC"),
            "user_01ABC"
        )
    }

    func testDefaultStateDBURLUsesRealHomeNotContainer() {
        let path = CursorSession.defaultStateDBURL.path
        XCTAssertFalse(path.contains("/Library/Containers/"), path)
        XCTAssertTrue(path.hasSuffix("Library/Application Support/Cursor/User/globalStorage/state.vscdb"), path)
        XCTAssertEqual(
            CursorSession.defaultStateDBURL.deletingLastPathComponent().path,
            CursorSession.realHomeDirectory
                .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
                .path
        )
    }

    func testNormalizeStripsAuth0FromPastedCookie() throws {
        let cookie = CursorSession.normalizeCookieValue(
            "auth0|user_01ABC%3A%3AeyJhbGciOiJub25lIn0.e30.sig"
        )
        XCTAssertEqual(cookie, "user_01ABC%3A%3AeyJhbGciOiJub25lIn0.e30.sig")
    }

    func testNormalizeDecodedDoubleColon() throws {
        let cookie = CursorSession.normalizeCookieValue("user_01ABC::eyJhbGciOiJub25lIn0.e30.sig")
        XCTAssertEqual(cookie, "user_01ABC%3A%3AeyJhbGciOiJub25lIn0.e30.sig")
    }

    func testNormalizeCookieHeader() throws {
        let raw = "Cookie: WorkosCursorSessionToken=user_01ABC%3A%3AeyJ.part.sig; Path=/"
        let cookie = CursorSession.normalizeCookieValue(raw)
        XCTAssertEqual(cookie, "user_01ABC%3A%3AeyJ.part.sig")
    }
}

final class L10nTests: XCTestCase {
    func testRequiredKeysExistInBothLanguages() {
        let keys = [
            "provider.cursor",
            "provider.claude",
            "provider.chatgpt",
            "menu.provider",
            "meter.cursorModels",
            "meter.otherModels",
            "meter.grokBot",
            "meter.fiveHour",
            "meter.sevenDay",
            "meter.window.weekly",
            "meter.codeReview",
            "spend.onDemand",
            "spend.extraUsage",
            "plan.reset.compact",
            "spend.amount.compact",
            "menu.pause",
            "menu.resume",
            "menu.refresh",
            "menu.paused",
            "menu.authNeeded.claude",
            "menu.authNeeded.chatgpt",
            "menu.credentialSaved",
            "error.unauthorized",
            "error.unauthorized.claude",
            "error.rateLimited",
            "error.apiKeyMode.claude",
            "error.apiKeyMode.chatgpt",
            "widget.placeholder"
        ]
        for key in keys {
            let ja = L10n.string(key, language: .ja)
            let en = L10n.string(key, language: .en)
            XCTAssertNotEqual(ja, key, "missing ja: \(key)")
            XCTAssertNotEqual(en, key, "missing en: \(key)")
            XCTAssertFalse(ja.isEmpty)
            XCTAssertFalse(en.isEmpty)
        }
    }

    func testPercentFormat() {
        XCTAssertEqual(L10n.format("meter.percentUsed", 100, language: .en), "100% used")
        XCTAssertEqual(L10n.format("meter.percentUsed", 100, language: .ja), "100% 使用")
    }

    func testCompactFormats() {
        XCTAssertEqual(
            L10n.format("plan.reset.compact", "9月16日", 11, language: .ja),
            "9月16日 · 残り11日"
        )
        XCTAssertEqual(
            L10n.format("plan.reset.compact", "Sep 16", 11, language: .en),
            "Sep 16 · 11d left"
        )
        XCTAssertEqual(
            L10n.format("spend.amount.compact", 44.48, 50.0, language: .en),
            "$44.48/$50"
        )
    }
}

final class UsageProviderRegistryTests: XCTestCase {
    func testRegistryIncludesCursorClaudeAndChatGPT() {
        XCTAssertEqual(UsageProviderRegistry.all.map(\.id), ["cursor", "claude", "chatgpt"])
        XCTAssertEqual(UsageProviderRegistry.defaultProviderID, "cursor")
        XCTAssertEqual(UsageProviderRegistry.provider(id: "claude")?.displayNameKey, "provider.claude")
        XCTAssertEqual(UsageProviderRegistry.provider(id: "chatgpt")?.dashboardURL.host, "chatgpt.com")
    }
}

final class ClaudeProviderMappingTests: XCTestCase {
    func testMapsProWindowsAndExtraUsage() throws {
        let usage = try decodeFixture("claude_oauth_usage_pro")
        let snap = ClaudeProvider.mapUsage(
            usage,
            accountLabel: "user@example.com",
            subscriptionType: "pro",
            rateLimitTier: "default_claude_pro",
            fetchedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snap.providerID, "claude")
        XCTAssertEqual(snap.plan.name, "Pro")
        XCTAssertEqual(snap.plan.priceText, "$20/mo")
        XCTAssertEqual(snap.accountLabel, "user@example.com")
        XCTAssertNotNil(snap.plan.resetAt)

        XCTAssertEqual(snap.meters.count, 4)
        XCTAssertEqual(snap.meters[0].id, "five-hour")
        XCTAssertEqual(snap.meters[0].percentUsed, 42.5, accuracy: 0.001)
        XCTAssertEqual(snap.meters[1].titleKey, "meter.sevenDay")
        XCTAssertEqual(snap.meters[2].titleKey, "meter.sevenDayOpus")
        XCTAssertEqual(snap.meters[2].percentUsed, 90, accuracy: 0.001)
        XCTAssertEqual(snap.meters[3].titleKey, "meter.sevenDaySonnet")

        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.titleKey, "spend.extraUsage")
        XCTAssertEqual(spend.usedUSD, 12.5, accuracy: 0.001)
        XCTAssertEqual(spend.limitUSD ?? -1, 50, accuracy: 0.001)
        XCTAssertFalse(spend.isUnlimited)
    }

    func testMapsStringPercentsAndUnixResetWithoutExtra() throws {
        let usage = try decodeFixture("claude_oauth_usage_no_extra")
        let snap = ClaudeProvider.mapUsage(
            usage,
            accountLabel: nil,
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_5x",
            fetchedAt: Date()
        )

        XCTAssertEqual(snap.plan.name, "Max")
        XCTAssertEqual(snap.plan.priceText, "$100/mo")
        XCTAssertEqual(snap.meters.count, 2)
        XCTAssertEqual(snap.meters[0].percentUsed, 7.2, accuracy: 0.001)
        XCTAssertEqual(snap.plan.resetAt, Date(timeIntervalSince1970: 1_770_000_000))
        XCTAssertNil(snap.spend)
    }

    func testDisplayPlanName() {
        XCTAssertEqual(ClaudeProvider.displayPlanName("pro"), "Pro")
        XCTAssertEqual(ClaudeProvider.displayPlanName("claude_max"), "Max")
        XCTAssertEqual(ClaudeProvider.displayPlanName(nil), "Claude")
    }

    private func decodeFixture(_ name: String) throws -> ClaudeOAuthUsageResponse {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
    }
}

final class ClaudeSessionTests: XCTestCase {
    func testNormalizeStripsBearerAndJSONRefresh() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-test","refreshToken":"do-not-use"}}"#
        XCTAssertEqual(ClaudeSession.normalizeToken("Bearer sk-ant-oat-test"), "sk-ant-oat-test")
        XCTAssertEqual(ClaudeSession.normalizeToken(json), "sk-ant-oat-test")
    }

    func testParseCredentialsJSONReadsMsExpiryAndPlan() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat-test",
            "expiresAt": 9999999999000,
            "subscriptionType": "pro",
            "rateLimitTier": "default_claude_pro",
            "email": "user@example.com"
          }
        }
        """
        let creds = try ClaudeSession.parseCredentialsJSON(Data(json.utf8))
        XCTAssertEqual(creds.accessToken, "sk-ant-oat-test")
        XCTAssertEqual(creds.subscriptionType, "pro")
        XCTAssertEqual(creds.email, "user@example.com")
        XCTAssertFalse(ClaudeSession.isExpired(expiresAt: creds.expiresAt, now: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    func testExpiresAtSecondsVsMilliseconds() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(ClaudeSession.isExpired(expiresAt: 1_699_999_000, now: now))
        XCTAssertTrue(ClaudeSession.isExpired(expiresAt: 1_699_999_000_000, now: now))
        XCTAssertFalse(ClaudeSession.isExpired(expiresAt: 1_800_000_000, now: now))
        XCTAssertFalse(ClaudeSession.isExpired(expiresAt: 1_800_000_000_000, now: now))
    }

    func testParseAPIKeyOnlyCredentialsThrows() {
        let json = #"{"mcpOAuth":{"example":true}}"#
        XCTAssertThrowsError(try ClaudeSession.parseCredentialsJSON(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ClaudeSessionError, .apiKeyMode)
        }
    }

    func testReadCredentialsFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-credentials-test.json")
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-file","subscriptionType":"team"}}"#
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let creds = try XCTUnwrap(try ClaudeSession.readCredentialsFile(fileURL: url))
        XCTAssertEqual(creds.accessToken, "sk-ant-oat-file")
        XCTAssertEqual(creds.subscriptionType, "team")
    }
}

final class ChatGPTProviderMappingTests: XCTestCase {
    func testPrefersCodexAdditionalWindow() throws {
        let usage = try decodeFixture("chatgpt_wham_usage_plus")
        let snap = ChatGPTProvider.mapUsage(
            usage,
            accountLabel: "user@example.com",
            fallbackPlanType: "free",
            fetchedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snap.providerID, "chatgpt")
        XCTAssertEqual(snap.plan.name, "Plus")
        XCTAssertEqual(snap.plan.priceText, "$20/mo")
        XCTAssertEqual(snap.accountLabel, "user@example.com")
        XCTAssertEqual(snap.plan.resetAt, Date(timeIntervalSince1970: 1_770_000_000))

        XCTAssertEqual(snap.meters.count, 3)
        XCTAssertEqual(snap.meters[0].titleKey, "meter.window.fiveHour")
        XCTAssertEqual(snap.meters[0].percentUsed, 55.5, accuracy: 0.001)
        XCTAssertEqual(snap.meters[1].titleKey, "meter.window.weekly")
        XCTAssertEqual(snap.meters[1].percentUsed, 12, accuracy: 0.001)
        XCTAssertEqual(snap.meters[2].titleKey, "meter.codeReview")
        XCTAssertEqual(snap.meters[2].percentUsed, 2, accuracy: 0.001)
        XCTAssertNil(snap.spend)
    }

    func testFallsBackToPrimaryRateLimit() throws {
        let usage = try decodeFixture("chatgpt_wham_usage_no_codex")
        let snap = ChatGPTProvider.mapUsage(
            usage,
            accountLabel: nil,
            fallbackPlanType: nil,
            fetchedAt: Date()
        )

        XCTAssertEqual(snap.plan.name, "Pro")
        XCTAssertEqual(snap.plan.priceText, "$200/mo")
        XCTAssertEqual(snap.meters.count, 1)
        XCTAssertEqual(snap.meters[0].titleKey, "meter.window.monthly")
        XCTAssertEqual(snap.meters[0].percentUsed, 41, accuracy: 0.001)
        XCTAssertNotNil(snap.plan.resetAt)
    }

    func testWindowTitleKeys() {
        XCTAssertEqual(ChatGPTProvider.windowTitleKey(seconds: 18_000), "meter.window.fiveHour")
        XCTAssertEqual(ChatGPTProvider.windowTitleKey(seconds: 86_400), "meter.window.daily")
        XCTAssertEqual(ChatGPTProvider.windowTitleKey(seconds: 604_800), "meter.window.weekly")
        XCTAssertEqual(ChatGPTProvider.windowTitleKey(seconds: 2_592_000), "meter.window.monthly")
        XCTAssertEqual(ChatGPTProvider.windowTitleKey(seconds: nil), "meter.window.primary")
    }

    func testDisplayPlanName() {
        XCTAssertEqual(ChatGPTProvider.displayPlanName("plus"), "Plus")
        XCTAssertEqual(ChatGPTProvider.displayPlanName("pro_lite"), "Pro Lite")
        XCTAssertEqual(ChatGPTProvider.displayPlanName(nil), "ChatGPT")
    }

    private func decodeFixture(_ name: String) throws -> ChatGPTUsageResponse {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ChatGPTUsageResponse.self, from: data)
    }
}

final class ChatGPTSessionTests: XCTestCase {
    func testNormalizeStripsBearerAndJSON() throws {
        let payload = jwtPayload(["sub": "user"])
        let json = #"{"tokens":{"access_token":"\#(payload)"}}"#
        XCTAssertEqual(ChatGPTSession.normalizeToken("Bearer \(payload)"), payload)
        XCTAssertEqual(ChatGPTSession.normalizeToken(json), payload)
    }

    func testParseAuthJSONPrefersExplicitAccountAndReadsPlan() throws {
        let access = jwtPayload([
            "https://api.openai.com/profile": ["email": "from-access@example.com"],
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "plus",
                "chatgpt_account_id": "acct_from_jwt"
            ]
        ])
        let json = """
        {
          "tokens": {
            "access_token": "\(access)",
            "account_id": "acct_explicit"
          }
        }
        """
        let auth = try ChatGPTSession.parseAuthJSON(Data(json.utf8))
        XCTAssertEqual(auth.accessToken, access)
        XCTAssertEqual(auth.accountID, "acct_explicit")
        XCTAssertEqual(auth.email, "from-access@example.com")
        XCTAssertEqual(auth.planType, "plus")
    }

    func testParseAPIKeyOnlyThrows() {
        let json = #"{"OPENAI_API_KEY":"sk-test"}"#
        XCTAssertThrowsError(try ChatGPTSession.parseAuthJSON(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ChatGPTSessionError, .apiKeyMode)
        }
    }

    func testReadCodexAuthFile() throws {
        let access = jwtPayload(["sub": "codex-user"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-auth-test.json")
        let json = #"{"tokens":{"access_token":"\#(access)"}}"#
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let auth = try XCTUnwrap(try ChatGPTSession.readCodexAuth(fileURL: url))
        XCTAssertEqual(auth.accessToken, access)
    }

    func testExpiredJWT() {
        let expired = jwtPayload(["exp": 1_000])
        XCTAssertTrue(ChatGPTSession.isExpired(expired, now: Date(timeIntervalSince1970: 2_000)))
        let fresh = jwtPayload(["exp": 9_999_999_999])
        XCTAssertFalse(ChatGPTSession.isExpired(fresh, now: Date(timeIntervalSince1970: 2_000)))
    }

    private func jwtPayload(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        var payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(payload).sig"
    }
}

final class DateParsingTests: XCTestCase {
    func testJSONNumberAcceptsStringAndInt() throws {
        let data = #"{"a":"3.5","b":8}"#.data(using: .utf8)!
        struct Box: Decodable {
            var a: JSONNumber
            var b: JSONNumber
        }
        let box = try JSONDecoder().decode(Box.self, from: data)
        XCTAssertEqual(box.a.value, 3.5, accuracy: 0.001)
        XCTAssertEqual(box.b.value, 8, accuracy: 0.001)
    }

    func testJSONTimestampAcceptsUnixAndISO() throws {
        let unix = try JSONDecoder().decode(JSONTimestamp.self, from: Data("1770000000".utf8))
        XCTAssertEqual(unix.date, Date(timeIntervalSince1970: 1_770_000_000))
        let iso = try JSONDecoder().decode(JSONTimestamp.self, from: Data(#""2026-09-21T18:00:00.000Z""#.utf8))
        XCTAssertEqual(DateParsing.iso8601("2026-09-21T18:00:00.000Z"), iso.date)
    }
}

