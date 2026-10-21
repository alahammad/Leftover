import Foundation

// Runs AdminMover's exact shell command (as the current user, without a password prompt)
// against files with awkward names, and checks the AppleScript quoting round-trips.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print("\(condition ? "PASS" : "FAIL")  \(message)")
    if !condition { failures += 1 }
}

let fm = FileManager.default
let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adminmover-\(getpid())")
let source = base.appendingPathComponent("src")
let target = base.appendingPathComponent("dst")
try fm.createDirectory(at: source, withIntermediateDirectories: true)
try fm.createDirectory(at: target, withIntermediateDirectories: true)

let names = ["Plain.app", "With Space.app", "It's quoted.app", "Dollar $HOME `x`.app", "Back\\slash \"dq\".app", "Ünïcødé 漢字.app"]
var moves: [AdminMover.Move] = []
for name in names {
    let from = source.appendingPathComponent(name)
    try fm.createDirectory(at: from, withIntermediateDirectories: true)
    moves.append(AdminMover.Move(from: from, to: target.appendingPathComponent(name)))
}
// One move that must fail (missing source) without stopping the others.
moves.insert(AdminMover.Move(from: source.appendingPathComponent("missing.app"), to: target.appendingPathComponent("missing.app")), at: 2)
// One that must not overwrite an existing destination.
let existing = target.appendingPathComponent("Exists.app")
try fm.createDirectory(at: existing, withIntermediateDirectories: true)
try "keep".write(to: existing.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
let clash = source.appendingPathComponent("Exists.app")
try fm.createDirectory(at: clash, withIntermediateDirectories: true)
moves.append(AdminMover.Move(from: clash, to: existing))

let command = AdminMover.shellCommand(for: moves)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/sh")
process.arguments = ["-c", command]
let pipe = Pipe()
process.standardOutput = pipe
process.standardError = FileHandle.nullDevice
try process.run()
process.waitUntilExit()
let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
let reported = Set(output.split(separator: "\n").compactMap { $0.hasPrefix("ok:") ? Int($0.dropFirst(3)) : nil })

check(process.terminationStatus == 0, "command exits 0 even when a move fails")
for (index, move) in moves.enumerated() {
    let name = move.from.lastPathComponent
    if name == "missing.app" {
        check(!reported.contains(index), "missing source reported as failed")
    } else if name == "Exists.app" {
        // mv -n onto an existing folder would move *into* it; the planner never targets existing names,
        // but make sure the original contents survive regardless.
        check(fm.fileExists(atPath: existing.appendingPathComponent("marker").path), "existing destination keeps its contents")
    } else {
        check(reported.contains(index) && fm.fileExists(atPath: move.to.path) && !fm.fileExists(atPath: move.from.path),
              "moved \(name)")
    }
}
check(!fm.fileExists(atPath: NSHomeDirectory() + "/x"), "no command substitution ran")

// The AppleScript literal must decode back to the same command.
let script = NSAppleScript(source: "return \(AdminMover.appleScriptQuoted(command))")
var error: NSDictionary?
let roundTrip = script?.executeAndReturnError(&error).stringValue
check(roundTrip == command, "AppleScript quoting round-trips the command")

// Trash planning avoids names already used in the batch.
let planned = AdminMover.trashMoves(for: [source.appendingPathComponent("A.app"), base.appendingPathComponent("A.app")])
check(planned[0].to.lastPathComponent != planned[1].to.lastPathComponent, "planned Trash names don't collide (\(planned.map(\.to.lastPathComponent)))")

try? fm.removeItem(at: base)
print(failures == 0 ? "All AdminMover tests passed" : "\(failures) AdminMover test(s) FAILED")
exit(failures == 0 ? 0 : 1)
