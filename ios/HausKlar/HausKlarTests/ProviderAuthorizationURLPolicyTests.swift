import XCTest

@testable import HausKlar

final class ProviderAuthorizationURLPolicyTests: XCTestCase {
    func testAcceptsOnlyExactProviderOriginsAndPaths() {
        XCTAssertNotNil(
            ProviderAuthorizationURLPolicy.validatedURL(
                "https://intervals.icu/oauth/authorize?client_id=one&state=two",
                provider: .intervals
            )
        )
        XCTAssertNotNil(
            ProviderAuthorizationURLPolicy.validatedURL(
                "https://www.strava.com/oauth/authorize?client_id=one",
                provider: .strava
            )
        )
        XCTAssertNotNil(
            ProviderAuthorizationURLPolicy.validatedURL(
                "https://account.withings.com/oauth2_user/authorize2?state=one",
                provider: .withings
            )
        )
        XCTAssertNotNil(
            ProviderAuthorizationURLPolicy.validatedURL(
                "https://auth.truelayer.com/session/one?state=two",
                provider: .trueLayer
            )
        )
    }

    func testRejectsPhishingUserInfoPortsDowngradesAndPathLookalikes() {
        let values = [
            "http://intervals.icu/oauth/authorize",
            "https://intervals.icu.evil.example/oauth/authorize",
            "https://demo-person-11@example.invalid/oauth/authorize",
            "https://user:demo-person-27@example.invalid/oauth/authorize",
            "https://intervals.icu:8443/oauth/authorize",
            "https://intervals.icu/oauth/authorize/extra",
            "https://intervals.icu/%6Fauth/authorize",
            "https://intervals.icu/oauth/authorize#fragment",
            "https://intervals.icu/oauth/authorize?state=one&state=two",
        ]
        for value in values {
            XCTAssertNil(
                ProviderAuthorizationURLPolicy.validatedURL(value, provider: .intervals),
                value
            )
        }
    }

    func testCallbacksHaveExactRouteAndSingleOutcome() throws {
        XCTAssertEqual(
            HausKlarAuthorizationCallback(
                url: try XCTUnwrap(URL(string: "hausklar://fitness/intervals?status=connected")),
                provider: .intervals
            ),
            .connected
        )
        XCTAssertEqual(
            HausKlarAuthorizationCallback(
                url: try XCTUnwrap(URL(string: "hausklar://finance-bank?bank=cancelled")),
                provider: .finance
            ),
            .cancelled
        )

        let invalid = [
            "hausklar://user:secret@fitness/intervals?status=connected",
            "hausklar://fitness/intervals/?status=connected",
            "hausklar://fitness/intervals?status=connected&extra=1",
            "hausklar://fitness/intervals?status=connected&status=failed",
            "hausklar://fitness/intervals?status=unknown",
            "hausklar://other/intervals?status=connected",
        ]
        for value in invalid {
            XCTAssertNil(
                HausKlarAuthorizationCallback(
                    url: try XCTUnwrap(URL(string: value)),
                    provider: .intervals
                ),
                value
            )
        }
    }
}
