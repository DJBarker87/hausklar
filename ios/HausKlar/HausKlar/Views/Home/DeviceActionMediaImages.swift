import SwiftUI

struct HomeMediaThumbnailView: View {
    let path: APIRequestPath
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.15))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: path) {
            image = nil
            let loaded = await HomeMediaThumbnailService.shared.image(
                for: path,
                maximumPixelSize: 160
            )
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
struct AudiobookCoverView: View {
    let itemId: String
    let cornerRadius: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(white: 0.15))
                    .overlay(
                        Image(systemName: "book.closed")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: itemId) {
            image = await AudiobookService.shared.fetchCoverImage(itemId: itemId)
        }
    }
}
