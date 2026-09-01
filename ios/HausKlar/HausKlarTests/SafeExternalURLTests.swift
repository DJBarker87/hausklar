import XCTest

@testable import HausKlar

final class SafeExternalURLTests: XCTestCase {
    func testWebAcceptsOnlyUncredentialedHTTPSAtDefaultPort() {
        XCTAssertEqual(
            SafeExternalURL.web(" https://example.com/a?b=c#result ")?.absoluteString,
            "https://example.com/a?b=c#result"
        )
        XCTAssertEqual(
            SafeExternalURL.web("https://example.com:443/path")?.host,
            "example.com"
        )

        XCTAssertNil(SafeExternalURL.web("http://example.com"))
        XCTAssertNil(SafeExternalURL.web("https://example.com:8443"))
        XCTAssertNil(SafeExternalURL.web("https://user:password@example.invalid"))
        XCTAssertNil(SafeExternalURL.web("file:///etc/passwd"))
        XCTAssertNil(SafeExternalURL.web("javascript:alert(1)"))
        XCTAssertNil(SafeExternalURL.web("//example.com/path"))
    }

    func testWebRejectsAmbiguousHostsControlsAndMalformedEscapes() {
        XCTAssertNil(SafeExternalURL.web("https://example..com"))
        XCTAssertNil(SafeExternalURL.web("https://-example.com"))
        XCTAssertNil(SafeExternalURL.web("https://example.com."))
        XCTAssertNil(SafeExternalURL.web("https://example.com/%"))
        XCTAssertNil(SafeExternalURL.web("https://example.com/%0G"))
        XCTAssertNil(SafeExternalURL.web("https://example.com/ok\u{000A}next"))
        XCTAssertNil(SafeExternalURL.web("https://example.com/\u{202E}hidden"))
        XCTAssertNil(SafeExternalURL.web("https://exämple.com"))
        XCTAssertNotNil(SafeExternalURL.web("https://xn--exmple-cua.com"))
    }

    func testContactNarrowlyAllowsSingleMailboxesAndTelephoneNumbers() {
        XCTAssertEqual(
            SafeExternalURL.contact("mailto:family@example.invalid")?.absoluteString,
            "mailto:family@example.invalid"
        )
        XCTAssertNotNil(SafeExternalURL.contact("tel:5550100"))
        XCTAssertNotNil(SafeExternalURL.contact("https://example.com/contact"))

        XCTAssertNil(SafeExternalURL.contact("mailto:first@example.invalid,second@example.invalid"))
        XCTAssertNil(SafeExternalURL.contact("mailto:family@example.invalid?body=secret"))
        XCTAssertNil(SafeExternalURL.contact("tel:*123#"))
        XCTAssertNil(SafeExternalURL.contact("sms:5550100"))
    }

    func testInputLengthIsBounded() {
        let oversized = "https://example.com/" + String(repeating: "a", count: 2_048)
        XCTAssertNil(SafeExternalURL.web(oversized))
    }
}
