import Foundation
import UIKit

public enum CrashReporter {

    private static let userDefaultsKey = "AppForTest.LastCrashReport"
    private static var serverBaseURL: String = "http://192.168.1.143:8080"

    public static func install(baseURL: URL? = nil) {
        if let baseURL {
            self.serverBaseURL = baseURL.absoluteString
        }

        // 1. Objective-C uncaught exception handler
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "Sin razón"
            let symbols = exception.callStackSymbols.prefix(8).joined(separator: "\n")
            let fullReport = "EXCEPTION [\(name)]: \(reason)\nStack:\n\(symbols)"

            CrashReporter.handleCrash(fullReport)
        }

        // 2. POSIX signal handlers
        let signals = [SIGABRT, SIGSEGV, SIGBUS, SIGTRAP, SIGILL]
        for sig in signals {
            signal(sig) { signum in
                let symbols = Thread.callStackSymbols.prefix(8).joined(separator: "\n")
                let fullReport = "SIGNAL [\(signum)]:\nStack:\n\(symbols)"

                CrashReporter.handleCrash(fullReport)

                // Re-raise signal so default handler terminates process
                signal(signum, SIG_DFL)
                kill(getpid(), signum)
            }
        }
    }

    /// Checks if a crash occurred during the previous session.
    public static func checkPreviousCrash() -> String? {
        guard let report = UserDefaults.standard.string(forKey: userDefaultsKey), !report.isEmpty else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.synchronize()
        return report
    }

    private static func handleCrash(_ report: String) {
        // 1. Persist locally to UserDefaults immediately
        UserDefaults.standard.set(report, forKey: userDefaultsKey)
        UserDefaults.standard.synchronize()

        // 2. Send synchronous HTTP GET request to Go server so it appears in server console log
        let truncated = String(report.prefix(500))
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "error"

        let urlString = "\(serverBaseURL)/v1/streams/crash?error=\(truncated)"
        if let url = URL(string: urlString) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 2.0

            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, _, _ in
                semaphore.signal()
            }.resume()

            _ = semaphore.wait(timeout: .now() + 2.0)
        }
    }
}

