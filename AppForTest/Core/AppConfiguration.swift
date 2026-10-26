import Foundation

struct AppConfiguration {
    let apiBaseURL: URL

    static let live = AppConfiguration(
        apiBaseURL: URL(string: "http://192.168.1.143:8080")!
    )
}
