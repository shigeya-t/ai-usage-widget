import SQLite3
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

    func testReadAccessTokenPrefersWALOverStaleMainFile() throws {
        let url = try makeStateDatabase()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        guard let db else { return }
        defer { sqlite3_close(db) }
        exec(db, "PRAGMA journal_mode=WAL;")
        exec(db, "PRAGMA wal_autocheckpoint=0;")
        exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);")
        exec(db, "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', 'old-token');")
        exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
        exec(db, "UPDATE ItemTable SET value = 'new-token' WHERE key = 'cursorAuth/accessToken';")

        XCTAssertEqual(tokenViaImmutable(url), "old-token")
        XCTAssertEqual(try CursorSession.readAccessToken(from: url), "new-token")
    }

    func testMissingTokenDoesNotCopyStateDatabase() throws {
        let url = try makeStateDatabase()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        guard let db else { return }
        exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);")
        sqlite3_close(db)

        let temp = FileManager.default.temporaryDirectory
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: temp.path))
        XCTAssertThrowsError(try CursorSession.readAccessToken(from: url)) { error in
            XCTAssertEqual(error as? CursorSessionError, .tokenMissing)
        }
        let after = try Set(FileManager.default.contentsOfDirectory(atPath: temp.path))
        let copies = after.subtracting(before).filter { $0.hasPrefix("aiusage-cursor-state-") }
        XCTAssertTrue(copies.isEmpty, "signed-out state copied the database: \(copies)")
    }

    private func makeStateDatabase() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("state.vscdb")
    }

    private func exec(_ db: OpaquePointer, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    private func tokenViaImmutable(_ url: URL) -> String? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2("file://\(url.path)?immutable=1", &db, flags, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: cString)
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
            "spend.credits",
            "spend.credits.balance",
            "spend.apiCost",
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
            "error.keychainDenied.claude",
            "error.apiKeyMode.chatgpt",
            "widget.placeholder"
        ]
        for key in keys {
            assertLocalized(key)
        }
    }

    func testProviderKeysFollowTheRegistry() {
        for provider in UsageProviderRegistry.all {
            for key in [
                provider.displayNameKey,
                provider.credentialNameKey,
                provider.authNeededKey,
                provider.usingAppKey,
                "error.unauthorized.\(provider.id)"
            ] {
                assertLocalized(key)
            }
        }
    }

    private func assertLocalized(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        let ja = L10n.string(key, language: .ja)
        let en = L10n.string(key, language: .en)
        XCTAssertNotEqual(ja, key, "missing ja: \(key)", file: file, line: line)
        XCTAssertNotEqual(en, key, "missing en: \(key)", file: file, line: line)
        XCTAssertFalse(ja.isEmpty, file: file, line: line)
        XCTAssertFalse(en.isEmpty, file: file, line: line)
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
        XCTAssertEqual(
            L10n.format("spend.credits.balance", "250", language: .ja),
            "残高 250"
        )
        XCTAssertEqual(
            L10n.format("spend.credits.balance", "12.34", language: .en),
            "12.34 credits"
        )
        XCTAssertEqual(UsageFormatting.formatCount(250), "250")
        XCTAssertEqual(UsageFormatting.formatCount(12.34), "12.34")
        let credits = SpendMeter(
            id: "credits",
            titleKey: "spend.credits",
            noteKey: nil,
            usedUSD: 250,
            limitUSD: nil,
            isUnlimited: true,
            remainingUSD: 250,
            unit: .credits
        )
        XCTAssertEqual(credits.formattedAmount(language: .ja, compact: false), "残高 250")
        XCTAssertEqual(credits.formattedAmount(language: .ja, compact: true), "残250")
        XCTAssertEqual(credits.formattedAmount(language: .en, compact: false), "250 credits")
    }
}

final class UsageProviderRegistryTests: XCTestCase {
    func testRegistryIncludesCursorClaudeAndChatGPT() {
        XCTAssertEqual(UsageProviderRegistry.all.map(\.id), ["cursor", "claude", "chatgpt"])
        XCTAssertEqual(UsageProviderRegistry.defaultProviderID, "cursor")
        XCTAssertEqual(UsageProviderRegistry.provider(id: "claude")?.displayNameKey, "provider.claude")
        XCTAssertEqual(
            UsageProviderRegistry.provider(id: "chatgpt")?.dashboardURL.absoluteString,
            "https://chatgpt.com/codex/settings/usage"
        )
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
        XCTAssertEqual(spend.noteKey, "spend.extraUsage.note")
        XCTAssertEqual(spend.usedUSD, 12.5, accuracy: 0.001)
        XCTAssertEqual(spend.limitUSD ?? -1, 50, accuracy: 0.001)
        XCTAssertFalse(spend.isUnlimited)
    }

    func testMapsCurrentSpendObjectEvenWhenDisabled() throws {
        let usage = try decodeFixture("claude_oauth_usage_spend")
        let snap = ClaudeProvider.mapUsage(
            usage,
            accountLabel: nil,
            subscriptionType: "pro",
            rateLimitTier: nil,
            fetchedAt: Date()
        )

        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.titleKey, "spend.extraUsage")
        XCTAssertEqual(spend.noteKey, "spend.extraUsage.outOfCredits")
        XCTAssertEqual(spend.usedUSD, 41.50, accuracy: 0.001)
        XCTAssertEqual(spend.limitUSD ?? -1, 100, accuracy: 0.001)
        XCTAssertFalse(spend.isUnlimited)
    }

    func testMapsLegacyExtraUsageMinorUnitsWhenSpendMissing() throws {
        let usage = try decodeFixture("claude_oauth_usage_extra_cents")
        let snap = ClaudeProvider.mapUsage(
            usage,
            accountLabel: nil,
            subscriptionType: "pro",
            rateLimitTier: nil,
            fetchedAt: Date()
        )

        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.usedUSD, 41.50, accuracy: 0.001)
        XCTAssertEqual(spend.limitUSD ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(spend.noteKey, "spend.extraUsage.outOfCredits")
    }

    func testHidesNeverPurchasedExtraUsage() throws {
        let usage = try decodeFixture("claude_oauth_usage_extra_disabled")
        let snap = ClaudeProvider.mapUsage(
            usage,
            accountLabel: nil,
            subscriptionType: "pro",
            rateLimitTier: nil,
            fetchedAt: Date()
        )
        XCTAssertNil(snap.spend)
    }

    func testUsdFromMinor() {
        XCTAssertEqual(ClaudeProvider.usdFromMinor(4150, decimalPlaces: 2) ?? -1, 41.50, accuracy: 0.001)
        XCTAssertEqual(ClaudeProvider.usdFromMinor(12.5, decimalPlaces: nil) ?? -1, 12.5, accuracy: 0.001)
        XCTAssertNil(ClaudeProvider.usdFromMinor(nil, decimalPlaces: 2))
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

    func testMapsOfficialCostReportCentsToUSD() throws {
        let report = try decodeCostFixture("claude_cost_report_month")
        let monthEnd = Date(timeIntervalSince1970: 1_759_276_800)
        let snap = ClaudeProvider.mapCostReport(report, monthEnd: monthEnd, fetchedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(snap.providerID, "claude")
        XCTAssertEqual(snap.plan.name, "API")
        XCTAssertEqual(snap.plan.resetAt, monthEnd)
        XCTAssertTrue(snap.meters.isEmpty)
        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.titleKey, "spend.apiCost")
        XCTAssertEqual(spend.usedUSD, 1.7345, accuracy: 0.0001)
        XCTAssertTrue(spend.isUnlimited)
    }

    func testUsdFromCentsString() {
        XCTAssertEqual(ClaudeProvider.usdFromCentsString("123.45"), 1.2345, accuracy: 0.0001)
        XCTAssertEqual(ClaudeProvider.usdFromCentsString("50"), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ClaudeProvider.usdFromCentsString(nil), 0)
    }

    private func decodeFixture(_ name: String) throws -> ClaudeOAuthUsageResponse {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
    }

    private func decodeCostFixture(_ name: String) throws -> ClaudeCostReportResponse {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClaudeCostReportResponse.self, from: data)
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

    func testParsePrefersClaudeAiOauthOverMcpPluginToken() throws {
        let json = """
        {
          "mcpOAuth": { "plugin:github|1": { "accessToken": "mcp-plugin-token" } },
          "claudeAiOauth": { "accessToken": "sk-ant-oat-real", "subscriptionType": "pro" }
        }
        """
        let creds = try ClaudeSession.parseCredentialsJSON(Data(json.utf8))
        XCTAssertEqual(creds.accessToken, "sk-ant-oat-real")
        XCTAssertEqual(creds.subscriptionType, "pro")
        XCTAssertNotNil(ClaudeSession.oauthCredsIfPresent(in: Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-real"}}"#.utf8)))
    }

    func testKeychainConfigSuffixIsSha256Prefix() {
        XCTAssertEqual(ClaudeSession.keychainConfigSuffix(forConfigDir: "hello"), "-2cf24dba")
        XCTAssertTrue(ClaudeSession.keychainServiceNames(configDir: "/tmp/claude-config").contains { $0.hasPrefix("Claude Code-credentials-") })
    }

    func testParseAPIKeyFromCredentialsJSON() {
        let json = #"{"ANTHROPIC_API_KEY":"sk-ant-api03-test"}"#
        let key = ClaudeSession.parseAPIKey(
            from: (try! JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])!
        )
        XCTAssertEqual(key, "sk-ant-api03-test")
        XCTAssertTrue(ClaudeSession.isAPIKey("sk-ant-admin01-abc"))
        XCTAssertFalse(ClaudeSession.isAPIKey("sk-ant-oat-test"))
        XCTAssertFalse(ClaudeSession.isAPIKey("sk-ant-oat01-abc"))
    }

    func testReadCredentialsFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-credentials-test.json")
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-file","subscriptionType":"team"}}"#
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let creds = try XCTUnwrap(try ClaudeSession.readCredentialsFile(fileURL: url))
        XCTAssertEqual(creds.accessToken, "sk-ant-oat-file")
        XCTAssertEqual(creds.subscriptionType, "team")
        let viaLoad = try XCTUnwrap(try ClaudeSession.loadLocalCredentials(fileURL: url, interactiveKeychain: false))
        XCTAssertEqual(viaLoad.accessToken, "sk-ant-oat-file")
    }

    func testEnvironmentOAuthTokenNameIsSeparateFromAPIKey() {
        XCTAssertFalse(ClaudeSession.isAPIKey("sk-ant-oat-ci-token"))
        XCTAssertEqual(ClaudeSession.normalizeToken("Bearer sk-ant-oat-ci-token"), "sk-ant-oat-ci-token")
    }

    func testExpiredLocalOAuthFallsBackToAdminKey() async throws {
        let url = try writeTempJSON(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-old","expiresAt":1}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let credential = try await ClaudeSession.resolveCredential(
            manualToken: "",
            environment: ["ANTHROPIC_ADMIN_KEY": "sk-ant-admin01-test"],
            credentialFiles: [url],
            includeKeychain: false
        )
        XCTAssertEqual(credential, .apiKey("sk-ant-admin01-test"))
    }

    func testExpiredLocalOAuthWithoutAPIKeyStaysExpired() async throws {
        let url = try writeTempJSON(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-old","expiresAt":1}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ClaudeSession.resolveCredential(
                manualToken: "",
                environment: [:],
                credentialFiles: [url],
                includeKeychain: false
            )
            XCTFail("expected tokenExpired")
        } catch ClaudeSessionError.tokenExpired {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testLoadLocalAPIKeyScansLaterCredentialFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-api-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent(".credentials.json")
        let second = dir.appendingPathComponent("credentials.json")
        try Data(#"{}"#.utf8).write(to: first)
        try Data(#"{"ANTHROPIC_API_KEY":"sk-ant-api03-from-second"}"#.utf8).write(to: second)
        XCTAssertEqual(
            ClaudeSession.loadLocalAPIKey(fileURLs: [first, second]),
            "sk-ant-api03-from-second"
        )
    }

    func testAPIKeyInLaterFileIsUsedWhenEarlierFileIsExpiredOAuth() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-mixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let expired = dir.appendingPathComponent(".credentials.json")
        let apiKey = dir.appendingPathComponent("credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-old","expiresAt":1}}"#.utf8).write(to: expired)
        try Data(#"{"ANTHROPIC_API_KEY":"sk-ant-api03-from-second"}"#.utf8).write(to: apiKey)
        let credential = try await ClaudeSession.resolveCredential(
            manualToken: "",
            environment: [:],
            credentialFiles: [expired, apiKey],
            includeKeychain: false
        )
        XCTAssertEqual(credential, .apiKey("sk-ant-api03-from-second"))
    }

    func testKeychainDenialFallsBackToAdminKey() throws {
        let credential = try ClaudeSession.selectCredential(
            manualRaw: nil,
            environmentOAuth: nil,
            local: nil,
            localError: .keychainDenied,
            apiKeyFromFiles: nil,
            environmentAPIKey: "sk-ant-admin01-test"
        )
        XCTAssertEqual(credential, .apiKey("sk-ant-admin01-test"))
    }

    func testKeychainDenialWithoutAPIKeyIsSurfaced() {
        XCTAssertThrowsError(
            try ClaudeSession.selectCredential(
                manualRaw: nil,
                environmentOAuth: nil,
                local: nil,
                localError: .keychainDenied,
                apiKeyFromFiles: nil,
                environmentAPIKey: nil
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeSessionError, .keychainDenied)
        }
    }

    private func writeTempJSON(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-session-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
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

        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.titleKey, "spend.credits")
        XCTAssertEqual(spend.unit, .credits)
        XCTAssertEqual(spend.remainingUSD ?? -1, 12.34, accuracy: 0.001)
        XCTAssertEqual(spend.formattedAmount(language: .ja, compact: false), "残高 12.34")
        XCTAssertEqual(spend.formattedAmount(language: .en, compact: false), "12.34 credits")
        XCTAssertTrue(spend.isUnlimited)
    }

    func testHidesCreditsWhenNotPurchased() throws {
        let usage = try decodeFixture("chatgpt_wham_usage_no_credits")
        let snap = ChatGPTProvider.mapUsage(
            usage,
            accountLabel: nil,
            fallbackPlanType: nil,
            fetchedAt: Date()
        )
        XCTAssertNil(snap.spend)
        XCTAssertEqual(snap.plan.name, "Go")
        XCTAssertEqual(snap.plan.priceText, "$8/mo")
    }

    func testMapsUnlimitedCreditsWithoutBalance() throws {
        let credits = ChatGPTCredits(hasCredits: true, unlimited: true, balance: nil)
        let spend = try XCTUnwrap(ChatGPTProvider.mapCredits(credits))
        XCTAssertEqual(spend.titleKey, "spend.credits")
        XCTAssertEqual(spend.unit, .credits)
        XCTAssertNil(spend.remainingUSD)
        XCTAssertTrue(spend.isUnlimited)
        XCTAssertEqual(spend.formattedAmount(language: .ja, compact: false), "無制限")
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
        XCTAssertNil(snap.spend)
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
        XCTAssertEqual(ChatGPTProvider.displayPlanName("go"), "Go")
        XCTAssertEqual(ChatGPTProvider.displayPlanName("free"), "Free")
        XCTAssertEqual(ChatGPTProvider.displayPlanName("pro_lite"), "Pro Lite")
        XCTAssertEqual(ChatGPTProvider.displayPlanName(nil), "ChatGPT")
    }

    func testMapsOfficialOrganizationCosts() throws {
        let costs = try decodeCostFixture("openai_organization_costs")
        let monthEnd = Date(timeIntervalSince1970: 1_759_276_800)
        let snap = ChatGPTProvider.mapCosts(costs, monthEnd: monthEnd, fetchedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(snap.providerID, "chatgpt")
        XCTAssertEqual(snap.plan.name, "API")
        XCTAssertTrue(snap.meters.isEmpty)
        let spend = try XCTUnwrap(snap.spend)
        XCTAssertEqual(spend.usedUSD, 12.75, accuracy: 0.001)
        XCTAssertTrue(spend.isUnlimited)
        XCTAssertEqual(spend.titleKey, "spend.apiCost")
    }

    private func decodeFixture(_ name: String) throws -> ChatGPTUsageResponse {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ChatGPTUsageResponse.self, from: data)
    }

    private func decodeCostFixture(_ name: String) throws -> OpenAICostsResponse {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(OpenAICostsResponse.self, from: data)
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

    func testParseAPIKeyOnlyThrowsFromOAuthParser() {
        let json = #"{"OPENAI_API_KEY":"sk-test"}"#
        XCTAssertThrowsError(try ChatGPTSession.parseAuthJSON(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ChatGPTSessionError, .apiKeyMode)
        }
    }

    func testParseCredentialPrefersOfficialAPIKeyWhenNoAccessToken() throws {
        let json = #"{"OPENAI_API_KEY":"sk-test"}"#
        let credential = try ChatGPTSession.parseCredential(Data(json.utf8))
        XCTAssertEqual(credential, .apiKey("sk-test"))
        XCTAssertTrue(ChatGPTSession.isAPIKey("sk-proj-abc"))
        XCTAssertFalse(ChatGPTSession.isAPIKey("sk-ant-api03-nope"))
        XCTAssertFalse(ChatGPTSession.isAPIKey("eyJhbGciOiJub25lIn0.e30.sig"))
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

    func testLoggedOutAuthFallsBackToAdminKey() throws {
        let url = try writeAuthJSON(#"{"tokens":null}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let credential = try ChatGPTSession.resolveCredential(
            manualToken: "",
            codexFileURL: url,
            environment: ["OPENAI_ADMIN_KEY": "sk-admin-test"]
        )
        XCTAssertEqual(credential, .apiKey("sk-admin-test"))
    }

    func testCorruptAuthFileFallsBackToAdminKey() throws {
        let url = try writeAuthJSON("not-json{{{")
        defer { try? FileManager.default.removeItem(at: url) }
        let credential = try ChatGPTSession.resolveCredential(
            manualToken: "",
            codexFileURL: url,
            environment: ["OPENAI_ADMIN_KEY": "sk-admin-test"]
        )
        XCTAssertEqual(credential, .apiKey("sk-admin-test"))
    }

    func testCorruptAuthFileWithoutAdminKeySurfacesReadError() throws {
        let url = try writeAuthJSON("not-json{{{")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(
            try ChatGPTSession.resolveCredential(
                manualToken: "",
                codexFileURL: url,
                environment: [:]
            )
        ) { error in
            XCTAssertFalse(error is ChatGPTSessionError)
        }
    }

    func testLoggedOutAuthWithoutAdminKeyIsMissing() throws {
        let url = try writeAuthJSON(#"{"tokens":null}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(
            try ChatGPTSession.resolveCredential(
                manualToken: "",
                codexFileURL: url,
                environment: [:]
            )
        ) { error in
            XCTAssertEqual(error as? ChatGPTSessionError, .tokenMissing)
        }
    }

    func testExpiredCodexTokenFallsBackOnlyWhenAdminKeyExists() throws {
        let expired = jwtPayload(["exp": 1_000])
        let url = try writeAuthJSON(#"{"tokens":{"access_token":"\#(expired)"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let fallback = try ChatGPTSession.resolveCredential(
            manualToken: "",
            codexFileURL: url,
            environment: ["OPENAI_ADMIN_KEY": "sk-admin-test"]
        )
        XCTAssertEqual(fallback, .apiKey("sk-admin-test"))
        XCTAssertThrowsError(
            try ChatGPTSession.resolveCredential(
                manualToken: "",
                codexFileURL: url,
                environment: [:]
            )
        ) { error in
            XCTAssertEqual(error as? ChatGPTSessionError, .tokenExpired)
        }
    }

    private func writeAuthJSON(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private func jwtPayload(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(payload).sig"
    }
}

final class BuildStampTests: XCTestCase {
    func testJoinsVersionAndCommit() {
        XCTAssertEqual(BuildStamp.label(version: "1.1.0", commit: "b4263b6c1a2f"), "1.1.0 · b4263b6c1a2f")
        XCTAssertEqual(BuildStamp.label(version: "1.1.0", commit: "b4263b6c1a2f-dirty"), "1.1.0 · b4263b6c1a2f-dirty")
    }

    func testOmitsUnsetCommitPlaceholder() {
        XCTAssertEqual(BuildStamp.label(version: "1.1.0", commit: "$(GIT_COMMIT_HASH)"), "1.1.0")
        XCTAssertEqual(BuildStamp.label(version: "  ", commit: nil), nil)
        XCTAssertEqual(BuildStamp.label(version: nil, commit: "abc1234"), "abc1234")
    }
}

final class MenuBarTitleTests: XCTestCase {
    func testShowsWorstMeterPercent() {
        let snap = UsageSnapshot(
            providerID: "cursor",
            accountLabel: nil,
            plan: PlanInfo(name: "Pro", priceText: nil, resetAt: nil),
            meters: [
                UsageMeter(id: "a", titleKey: "meter.cursorModels", subtitleKey: nil, percentUsed: 10, accent: .primary),
                UsageMeter(id: "b", titleKey: "meter.otherModels", subtitleKey: nil, percentUsed: 40, accent: .secondary)
            ],
            spend: nil,
            fetchedAt: Date(),
            errorMessage: nil
        )
        XCTAssertEqual(snap.menuBarValue(language: .en), "40%")
    }

    func testShowsAPISpendWhenMetersAreEmpty() {
        let snap = UsageSnapshot(
            providerID: "claude",
            accountLabel: nil,
            plan: PlanInfo(name: "API", priceText: nil, resetAt: nil),
            meters: [],
            spend: SpendMeter(
                id: "api-cost",
                titleKey: "spend.apiCost",
                noteKey: "spend.apiCost.note",
                usedUSD: 12.75,
                limitUSD: nil,
                isUnlimited: true
            ),
            fetchedAt: Date(),
            errorMessage: nil
        )
        XCTAssertEqual(snap.menuBarValue(language: .en), "$12.75/∞")
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

    func testUTCMonthBounds() {
        let date = Date(timeIntervalSince1970: 1_789_948_800) // 2026-09-21T00:00:00Z
        let bounds = DateParsing.utcMonthBounds(containing: date)
        XCTAssertEqual(bounds.start, Date(timeIntervalSince1970: 1_788_220_800)) // 2026-09-01T00:00:00Z
        XCTAssertEqual(bounds.end, Date(timeIntervalSince1970: 1_790_812_800)) // 2026-10-01T00:00:00Z
    }
}

