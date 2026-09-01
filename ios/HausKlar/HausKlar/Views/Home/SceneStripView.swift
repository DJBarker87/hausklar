import SwiftUI

struct SceneStripView: View {
    let scenes: [HomeViewModel.SceneInfo]
    let onActivate: (String) -> Void
    let onToggleFavorite: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(scenes) { scene in
                    sceneButton(scene)
                }
            }
            .padding(.horizontal)
        }
    }

    private func sceneButton(_ scene: HomeViewModel.SceneInfo) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            onActivate(scene.entityId)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: scene.icon)
                    .font(.system(size: 12))
                Text(scene.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Color.hackerGreen)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .stroke(Color.hackerGreen.opacity(0.3), lineWidth: 1)
                    .background(Color.hackerGreen.opacity(0.08), in: Capsule())
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onToggleFavorite(scene.entityId)
            } label: {
                Label(
                    scene.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: scene.isFavorite ? "star.slash" : "star.fill"
                )
            }
        }
    }
}
