import SwiftUI
import UIKit

@MainActor
struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    @StateObject private var apiTestViewModel: APITestViewModel
    @State private var showAPIMenu = false

    private let imageLoader: PhotoImageLoading
    private let savePhotoToLibrary: SavePhotoToLibraryUseCase

    init(container: AppContainer) {
        _viewModel = StateObject(wrappedValue: HomeViewModel(
            loadPhotos: container.loadPhotos,
            capturePhoto: container.capturePhoto,
            deletePhoto: container.deletePhoto,
            cameraAuthorization: container.cameraAuthorization
        ))
        _apiTestViewModel = StateObject(wrappedValue: APITestViewModel(
            repository: container.apiTestRepository,
            syncPhotosUseCase: container.syncPhotos,
            loadPhotosUseCase: container.loadPhotos
        ))
        self.imageLoader = container.imageLoader
        self.savePhotoToLibrary = container.savePhotoToLibrary
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .trailing) {
                mainContent

                if showAPIMenu {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { closeAPIMenu() }
                        .transition(.opacity)

                    APITestMenuView(model: apiTestViewModel) {
                        closeAPIMenu()
                    }
                    .frame(width: 330)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
                }
            }
            .navigationTitle("AppForTest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAPIMenu.toggle()
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("Pruebas de API")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showAPIMenu)
        }
        .onAppear {
            viewModel.onAppear()
        }
        .fullScreenCover(isPresented: $viewModel.isCameraPresented) {
            CameraView { image in
                viewModel.capture(image)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $viewModel.capturedPhoto, onDismiss: {
            viewModel.refresh()
        }) { photo in
            PhotoPreviewView(
                photo: photo,
                imageLoader: imageLoader,
                savePhotoToLibrary: savePhotoToLibrary,
                onDiscard: { viewModel.delete(photo) }
            )
        }
        .fullScreenCover(item: $viewModel.viewerPhoto, onDismiss: {
            viewModel.refresh()
        }) { photo in
            PhotoViewerView(
                photo: photo,
                imageLoader: imageLoader,
                savePhotoToLibrary: savePhotoToLibrary,
                onDelete: { viewModel.delete(photo) }
            )
        }
        .alert(item: $viewModel.alertItem) { item in
            if item.showsSettingsButton {
                return Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    primaryButton: .default(Text("Abrir Ajustes"), action: openSettings),
                    secondaryButton: .cancel(Text("Cerrar"))
                )
            }
            return Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                Button(action: viewModel.openCamera) {
                    Label("Abrir cámara", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)
                .padding(.top, 16)
            }
            .padding()

            Divider()

            GalleryView(
                photos: viewModel.photos,
                imageLoader: imageLoader,
                onSelect: { viewModel.select($0) }
            )
        }
    }

    private func closeAPIMenu() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showAPIMenu = false
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    HomeView(container: AppContainer())
}
