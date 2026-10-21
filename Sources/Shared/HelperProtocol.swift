import Foundation

/// XPC interface of the privileged helper.
///
/// Clients only name the item to trash (or the ledger token to restore). The helper
/// chooses every destination itself, so a client can never use it to move files
/// to arbitrary places as root.
@objc protocol LeftoverHelperProtocol {
    func version(withReply reply: @escaping (String) -> Void)

    /// Moves `path` into the calling user's Trash.
    /// Reply: (ledger token, path inside the Trash, error message).
    func trashItem(atPath path: String, withReply reply: @escaping (String?, String?, String?) -> Void)

    /// Puts an item this helper trashed back where it came from.
    /// Reply: error message, or nil on success.
    func restoreItem(token: String, withReply reply: @escaping (String?) -> Void)
}

extension BuildConfig {
    /// Code-signing requirement used on both ends of the XPC connection.
    /// Nil for ad-hoc builds, which means the helper accepts nobody.
    static func requirement(identifier: String) -> String? {
        guard !teamID.isEmpty else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
