import Foundation

struct HealthStatus: Equatable {
    let status: String

    var isHealthy: Bool { status.lowercased() == "ok" }
}

struct DeviceSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let platform: String
    let recordCount: Int
}

struct RemoteRecord: Identifiable, Hashable {
    let id: String
    let fileName: String
    let fileSize: UInt64
    let contentType: String
    let dataCategory: String
    let sha256: Data
}

struct PhotoSearchResult: Equatable {
    let records: [RemoteRecord]
    let totalCount: Int
}

struct UploadSummary: Equatable {
    let deviceID: String
    let transferID: String
    let fileName: String
    let success: Bool
}

struct TransferStatusSummary: Equatable {
    let nextChunkIndex: Int
    let nextChunkOffset: UInt64
}

struct DownloadSummary: Equatable {
    let fileName: String
    let fileSize: UInt64
    let destination: URL
    let sha256: Data
}

struct SyncReport: Equatable {
    let deviceID: String?
    let uploadedCount: Int
    let skippedCount: Int
    let failedCount: Int
    let remoteRecordCount: Int
    let records: [RemoteRecord]
    let failures: [String]

    static let noPhotos = SyncReport(
        deviceID: nil,
        uploadedCount: 0,
        skippedCount: 0,
        failedCount: 0,
        remoteRecordCount: 0,
        records: [],
        failures: []
    )
}
