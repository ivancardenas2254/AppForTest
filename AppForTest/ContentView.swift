import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("¡Hola desde AppForTest!")
                .font(.title)
                .fontWeight(.bold)

            Text("Esta es una app de prueba lista para compilar e instalar.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
