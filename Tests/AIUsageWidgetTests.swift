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
            "meter.cursorModels",
            "meter.otherModels",
            "meter.grokBot",
            "spend.onDemand",
            "plan.reset.compact",
            "spend.amount.compact",
            "menu.pause",
            "menu.resume",
            "menu.refresh",
            "menu.paused",
            "error.unauthorized",
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
