import SwiftUI

@main
struct AppForTestApp: App {
    private let container = AppContainer()

    init() {
        CrashReporter.install(baseURL: AppConfiguration.live.apiBaseURL)
    }

    var body: some Scene {
        WindowGroup {
            HomeView(container: container)
        }
    }
}
