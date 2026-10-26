import Foundation

struct Photo: Identifiable, Hashable {
    let url: URL
    let createdAt: Date

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
}
