import Foundation
import MDTPClient

struct SHA256PhotoHasher: PhotoHashing {
    func hash(fileAt url: URL) throws -> Data {
        try MDTPSHA256.hash(fileAt: url)
    }
}
