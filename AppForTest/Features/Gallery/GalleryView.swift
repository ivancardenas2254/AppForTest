import SwiftUI

struct GalleryView: View {
    let photos: [Photo]
    let imageLoader: PhotoImageLoading
    let onSelect: (Photo) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        if photos.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(photos) { photo in
                        Button {
                            onSelect(photo)
                        } label: {
                            PhotoThumbnailView(photo: photo, imageLoader: imageLoader)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Aún no hay fotos")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Toma tu primera foto con el botón de arriba.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
