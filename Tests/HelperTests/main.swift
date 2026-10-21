import Foundation

// Exercises the helper's real code (PathPolicy, SafeFS, Ledger, HelperSession) as the
// current user, without launchd or root. Run with Tests/run-helper-tests.sh.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print("\(condition ? "PASS" : "FAIL")  \(message)")
    if !condition { failures += 1 }
}

let fm = FileManager.default
let home = try PathPolicy.homeDirectory(for: getuid())
let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("leftover-tests-\(getpid())")
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
let session = HelperSession(
    uid: getuid(),
    ledger: Ledger(url: scratch.appendingPathComponent("ledger.plist")),
    stagingFolder: try SafeFS.realPath(scratch.path) + "/staging")

func trash(_ path: String) -> (token: String?, trashed: String?, error: String?) {
    var result: (String?, String?, String?) = (nil, nil, nil)
    session.trashItem(atPath: path) { result = ($0, $1, $2) }
    return result
}

func restore(_ token: String) -> String? {
    var error: String?
    session.restoreItem(token: token) { error = $0 }
    return error
}

// 1. Paths the helper must refuse.
let forbidden = [
    "/etc/hosts",
    "/System/Library/CoreServices/Finder.app",
    "/usr/bin/true",
    "/Library/Preferences",                       // an allowed root itself, not an item inside it
    home + "/Documents",
    home + "/Library/Caches/../../Documents",     // traversal
    "relative/path",
    "/private/var/db/../../etc/hosts",
]
for path in forbidden {
    check(trash(path).error != nil, "refuses \(path)")
}

// 2. Round trip on an allowed path.
let item = home + "/Library/Caches/com.example.leftover-helpertest"
try fm.createDirectory(atPath: item, withIntermediateDirectories: true)
try "data".write(toFile: item + "/file", atomically: true, encoding: .utf8)

let moved = trash(item)
check(moved.token != nil && moved.error == nil, "trashes \(item) \(moved.error ?? "")")
check(!fm.fileExists(atPath: item), "item left its original folder")
check(moved.trashed.map { fm.fileExists(atPath: $0) } == true, "item is in the Trash at \(moved.trashed ?? "-")")
if let token = moved.token {
    check(restore(token) == nil, "restores it")
    check(fm.fileExists(atPath: item + "/file"), "item is back with its contents")
    check(restore(token) != nil, "a token can't be used twice")
}

// 3. A swapped item in the Trash must not be restored.
let second = trash(item)
if let token = second.token, let trashed = second.trashed {
    try fm.removeItem(atPath: trashed)
    try fm.createDirectory(atPath: trashed, withIntermediateDirectories: false)   // same name, different inode
    let error = restore(token)
    check(error != nil, "refuses to restore a replaced item (\(error ?? "restored!"))")
    try? fm.removeItem(atPath: trashed)
} else {
    check(false, "second trash failed: \(second.error ?? "")")
}

// 4. Name collisions in the Trash get a counter instead of overwriting.
try fm.createDirectory(atPath: item, withIntermediateDirectories: true)
let blocker = home + "/.Trash/com.example.leftover-helpertest"
try? fm.createDirectory(atPath: blocker, withIntermediateDirectories: true)
let third = trash(item)
check(third.trashed?.hasSuffix("com.example.leftover-helpertest 2") == true, "avoids overwriting (\(third.trashed ?? "-"))")
if let token = third.token { _ = restore(token) }

// Clean up.
try? fm.removeItem(atPath: item)
try? fm.removeItem(atPath: blocker)
try? fm.removeItem(at: scratch)

print(failures == 0 ? "All helper tests passed" : "\(failures) helper test(s) FAILED")
exit(failures == 0 ? 0 : 1)
