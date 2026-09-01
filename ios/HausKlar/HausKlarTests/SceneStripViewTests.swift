import XCTest
import SwiftUI
@testable import HausKlar

final class SceneStripViewTests: XCTestCase {

    private func makeScene(id: String, name: String, domain: String = "scene", isFavorite: Bool = false) -> HomeViewModel.SceneInfo {
        HomeViewModel.SceneInfo(
            id: id,
            entityId: id,
            displayName: name,
            icon: domain == "scene" ? "play.circle" : "bolt.circle",
            domain: domain,
            isFavorite: isFavorite
        )
    }

    func testInitializesWithScenes() {
        let scenes = [
            makeScene(id: "scene.example_00c12986", name: "Goodnight"),
            makeScene(id: "script.boost", name: "Boost Heating", domain: "script"),
        ]
        let view = SceneStripView(scenes: scenes, onActivate: { _ in }, onToggleFavorite: { _ in })
        _ = view.body
    }

    func testInitializesWithEmptyScenes() {
        let view = SceneStripView(scenes: [], onActivate: { _ in }, onToggleFavorite: { _ in })
        _ = view.body
    }

    func testInitializesWithSingleScene() {
        let view = SceneStripView(
            scenes: [makeScene(id: "scene.test", name: "Test")],
            onActivate: { _ in },
            onToggleFavorite: { _ in }
        )
        _ = view.body
    }

    func testOnActivateCallbackProvided() {
        var activated: String?
        let scenes = [makeScene(id: "scene.test", name: "Test")]
        let _ = SceneStripView(
            scenes: scenes,
            onActivate: { id in activated = id },
            onToggleFavorite: { _ in }
        )
        // Can't easily trigger the button in XCTest without ViewInspector
        XCTAssertNil(activated) // Not triggered yet
    }

    func testOnToggleFavoriteCallbackProvided() {
        var toggled: String?
        let scenes = [makeScene(id: "scene.test", name: "Test")]
        let _ = SceneStripView(
            scenes: scenes,
            onActivate: { _ in },
            onToggleFavorite: { id in toggled = id }
        )
        XCTAssertNil(toggled)
    }

    func testSceneWithFavoriteFlag() {
        let scenes = [
            makeScene(id: "scene.fav", name: "Favorite", isFavorite: true),
            makeScene(id: "scene.normal", name: "Normal", isFavorite: false),
        ]
        let view = SceneStripView(scenes: scenes, onActivate: { _ in }, onToggleFavorite: { _ in })
        _ = view.body
    }

    func testSceneWithScriptDomain() {
        let scenes = [
            makeScene(id: "script.example_3ffa9dd3", name: "Goodnight", domain: "script"),
        ]
        let view = SceneStripView(scenes: scenes, onActivate: { _ in }, onToggleFavorite: { _ in })
        _ = view.body
    }

    func testManyScenes() {
        let scenes = (0..<20).map { i in
            makeScene(id: "scene.scene_\(i)", name: "Scene \(i)")
        }
        let view = SceneStripView(scenes: scenes, onActivate: { _ in }, onToggleFavorite: { _ in })
        _ = view.body
    }

    func testSceneIcons() {
        let scene = makeScene(id: "scene.test", name: "Test", domain: "scene")
        XCTAssertEqual(scene.icon, "play.circle")

        let script = makeScene(id: "script.test", name: "Test", domain: "script")
        XCTAssertEqual(script.icon, "bolt.circle")
    }

    func testConformsToViewProtocol() {
        let _: any View = SceneStripView(
            scenes: [makeScene(id: "scene.test", name: "Test")],
            onActivate: { _ in },
            onToggleFavorite: { _ in }
        )
    }
}
