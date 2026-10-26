import SwiftUI
import UIKit

struct PhotoThumbnailView: View {
    let photo: Photo
    let imageLoader: PhotoImageLoading

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(ProgressView())
            }
        }
        .clipped()
        .task {
            image = imageLoader.thumbnail(for: photo, maxPixelSize: 400)
        }
    }
}
