import SwiftUI

struct APITestMenuView: View {
    @ObservedObject var model: APITestViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    status
                    action("Conexión (devices/list)", systemImage: "antenna.radiowaves.left.and.right") {
                        Task { @MainActor in await model.checkConnection() }
                    }
                    action("Health GET /health", systemImage: "heart.text.square") {
                        Task { @MainActor in await model.checkHealth() }
                    }
                    action("Sincronizar todas las fotos", systemImage: "icloud.and.arrow.up") {
                        Task { @MainActor in await model.syncPhotos() }
                    }
                    Divider()
                    action("Registrar dispositivo", systemImage: "iphone.gen3") {
                        Task { @MainActor in await model.registerDevice() }
                    }
                    action("Listar dispositivos", systemImage: "list.bullet.rectangle") {
                        Task { @MainActor in await model.listDevices() }
                    }
                    action("Buscar fotos", systemImage: "photo.magnifyingglass") {
                        Task { @MainActor in await model.searchPhotos() }
                    }
                    action("Obtener primer registro", systemImage: "doc.text.magnifyingglass") {
                        Task { @MainActor in await model.getFirstRecord() }
                    }
                    action("Subir última foto", systemImage: "arrow.up.circle") {
                        Task { @MainActor in await model.uploadLatestPhoto() }
                    }
                    action("Estado de última transferencia", systemImage: "arrow.triangle.2.circlepath") {
                        Task { @MainActor in await model.transferStatus() }
                    }
                    action("Descargar primer registro", systemImage: "arrow.down.circle") {
                        Task { @MainActor in await model.downloadFirstRecord() }
                    }
                    Divider()
                    logSection
                }
                .padding(16)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(width: 1)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pruebas API")
                    .font(.title3.bold())
                Text(model.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel("Cerrar menú")
        }
        .padding(16)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Dispositivo: \(model.deviceLabel)", systemImage: "iphone")
            Label("Registros: \(model.recordsLabel)", systemImage: "photo.on.rectangle")
            if model.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Trabajando...")
                }
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Resultados")
                    .font(.headline)
                Spacer()
                Button("Limpiar") {
                    model.clearLog()
                }
                .font(.caption)
            }
            if model.log.isEmpty {
                Text("Todavía no ejecutaste ninguna prueba.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func action(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(
                    Color.accentColor.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .opacity(model.isBusy ? 0.5 : 1)
    }
}

