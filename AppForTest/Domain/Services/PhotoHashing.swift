import Foundation

protocol PhotoHashing {
    func hash(fileAt url: URL) throws -> Data
}
