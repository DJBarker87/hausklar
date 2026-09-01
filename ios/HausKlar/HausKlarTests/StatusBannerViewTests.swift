import XCTest
import SwiftUI
@testable import HausKlar

final class StatusBannerViewTests: XCTestCase {

    func testInitializesWithAllParameters() {
        let view = StatusBannerView(
            temperature: "20.5\u{00B0}C",
            lightsOn: 3,
            totalLights: 8,
            doorSummary: "ALL CLOSED",
            sonosSummary: "\u{266A} Africa"
        )
        _ = view.body
    }

    func testInitializesWithNilOptionals() {
        let view = StatusBannerView(
            temperature: nil,
            lightsOn: 0,
            totalLights: 0,
            doorSummary: "ALL CLOSED",
            sonosSummary: nil
        )
        _ = view.body
    }

    func testInitializesWithOpenDoorSummary() {
        let view = StatusBannerView(
            temperature: "20.0\u{00B0}C",
            lightsOn: 1,
            totalLights: 5,
            doorSummary: "FRONT DOOR OPEN",
            sonosSummary: nil
        )
        _ = view.body
    }

    func testInitializesWithZeroLights() {
        let view = StatusBannerView(
            temperature: "18.0\u{00B0}C",
            lightsOn: 0,
            totalLights: 5,
            doorSummary: "ALL CLOSED",
            sonosSummary: nil
        )
        _ = view.body
    }

    func testInitializesWithMultipleLightsOn() {
        let view = StatusBannerView(
            temperature: "21.0\u{00B0}C",
            lightsOn: 5,
            totalLights: 8,
            doorSummary: "ALL CLOSED",
            sonosSummary: "\u{266A} Calm Piano"
        )
        _ = view.body
    }

    func testInitializesWithEmptyDoorSummary() {
        let view = StatusBannerView(
            temperature: nil,
            lightsOn: 0,
            totalLights: 0,
            doorSummary: "",
            sonosSummary: nil
        )
        _ = view.body
    }

    func testInitializesWithLongSonosSummary() {
        let view = StatusBannerView(
            temperature: "20.0\u{00B0}C",
            lightsOn: 3,
            totalLights: 5,
            doorSummary: "ALL CLOSED",
            sonosSummary: "\u{266A} Very Long Song Title That Might Overflow"
        )
        _ = view.body
    }

    func testConformsToViewProtocol() {
        let _: any View = StatusBannerView(
            temperature: "20.0\u{00B0}C",
            lightsOn: 1,
            totalLights: 5,
            doorSummary: "ALL CLOSED",
            sonosSummary: nil
        )
    }

    func testMultipleDoorsOpen() {
        let view = StatusBannerView(
            temperature: "20.0\u{00B0}C",
            lightsOn: 0,
            totalLights: 5,
            doorSummary: "FRONT DOOR, BACK DOOR OPEN",
            sonosSummary: nil
        )
        _ = view.body
    }

    func testMaxValues() {
        let view = StatusBannerView(
            temperature: "99.9\u{00B0}C",
            lightsOn: 100,
            totalLights: 100,
            doorSummary: "ALL CLOSED",
            sonosSummary: "\u{266A} Test"
        )
        _ = view.body
    }
}
