import Foundation

enum CameraAccessStatus {
    case authorized
    case notDetermined
    case denied
}

protocol CameraAuthorization {
    var isCameraAvailable: Bool { get }
    func status() -> CameraAccessStatus
    func requestAccess() async -> Bool
}
