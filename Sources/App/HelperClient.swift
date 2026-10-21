import Foundation
import ServiceManagement

enum HelperError: LocalizedError {
    case unsigned
    case notEnabled
    case badProxy
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .unsigned:
            "This copy of Leftover isn't signed with a developer certificate, so its helper can't be installed. Files owned by the system can't be removed."
        case .notEnabled:
            "Leftover's helper isn't enabled. Install it from the banner, then allow it in System Settings › General › Login Items."
        case .badProxy:
            "Couldn't talk to Leftover's helper."
        case .remote(let message):
            message
        }
    }
}

/// Registers the privileged helper with SMAppService and talks to it over XPC.
final class HelperClient: @unchecked Sendable {
    enum Status: Equatable {
        case unsigned, notRegistered, requiresApproval, enabled
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var service: SMAppService { SMAppService.daemon(plistName: BuildConfig.helperPlistName) }

    var status: Status {
        guard !BuildConfig.teamID.isEmpty else { return .unsigned }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .notRegistered
        }
    }

    func register() throws {
        guard status != .unsigned else { throw HelperError.unsigned }
        try service.register()
    }

    /// Replaces a helper left over from an older build of the app.
    func reregister() async throws {
        dropConnection()
        try await service.unregister()
        try service.register()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func version() async throws -> String {
        try await call { proxy, once in
            proxy.version { once.resume(.success($0)) }
        }
    }

    func trash(path: String) async throws -> (token: String, trashedPath: String) {
        try await call { proxy, once in
            proxy.trashItem(atPath: path) { token, trashedPath, error in
                if let token, let trashedPath {
                    once.resume(.success((token, trashedPath)))
                } else {
                    once.resume(.failure(HelperError.remote(error ?? "The helper couldn't move \(path).")))
                }
            }
        }
    }

    func restore(token: String) async throws {
        try await call { proxy, once in
            proxy.restoreItem(token: token) { error in
                once.resume(error.map { .failure(HelperError.remote($0)) } ?? .success(()))
            }
        }
    }

    private func call<T>(_ body: @escaping (LeftoverHelperProtocol, ResumeOnce<T>) -> Void) async throws -> T {
        switch status {
        case .unsigned: throw HelperError.unsigned
        case .enabled: break
        default: throw HelperError.notEnabled
        }
        let connection = currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { once.resume(.failure($0)) }
            guard let helper = proxy as? LeftoverHelperProtocol else {
                once.resume(.failure(HelperError.badProxy))
                return
            }
            body(helper, once)
        }
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        let connection = NSXPCConnection(machServiceName: BuildConfig.helperLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LeftoverHelperProtocol.self)
        if let requirement = BuildConfig.requirement(identifier: BuildConfig.helperLabel) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.invalidationHandler = { [weak self] in self?.dropConnection() }
        connection.interruptionHandler = { [weak self] in self?.dropConnection() }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func dropConnection() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        old?.invalidate()
    }
}

/// XPC can call both the reply and the error handler; only the first may resume.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
