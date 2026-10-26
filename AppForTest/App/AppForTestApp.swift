import SwiftUI

@main
struct AppForTestApp: App {
    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            HomeView(container: container)
        }
    }
}
