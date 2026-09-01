import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import HausKlar

final class SensitiveClipboardTests: XCTestCase {
    func testPayloadIsLocalOnlyAndShortLived() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let payload = try XCTUnwrap(
            SensitiveClipboard.payload(
                "private-token",
                expiresAt: now.addingTimeInterval(600),
                maximumLifetime: 120,
                now: now
            )
        )

        XCTAssertEqual(payload.options[.localOnly] as? Bool, true)
        XCTAssertEqual(payload.options[.expirationDate] as? Date, now.addingTimeInterval(120))
        XCTAssertEqual(
            payload.items.first?[UTType.utf8PlainText.identifier] as? String,
            "private-token"
        )
    }

    func testUnderlyingTokenExpiryWins() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let tokenExpiry = now.addingTimeInterval(30)
        let payload = try XCTUnwrap(
            SensitiveClipboard.payload(
                "private-token",
                expiresAt: tokenExpiry,
                maximumLifetime: 120,
                now: now
            )
        )
        XCTAssertEqual(payload.expirationDate, tokenExpiry)
    }

    func testExpiredEmptyAndOversizedSecretsAreNotCopied() {
        let now = Date(timeIntervalSince1970: 3_000)
        XCTAssertNil(
            SensitiveClipboard.payload("", expiresAt: nil, maximumLifetime: 120, now: now)
        )
        XCTAssertNil(
            SensitiveClipboard.payload(
                "token",
                expiresAt: now,
                maximumLifetime: 120,
                now: now
            )
        )
        XCTAssertNil(
            SensitiveClipboard.payload(
                String(repeating: "a", count: 4_097),
                expiresAt: nil,
                maximumLifetime: 120,
                now: now
            )
        )
    }
}
