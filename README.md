# Leftover

Drag an app in, and Leftover finds the files the app left around your Mac and moves everything to the Trash. Files owned by the system, such as launch daemons, privileged helpers and installer receipts, are moved by a small root helper.

## Build

```sh
./build.sh                     # universal app at build/Leftover.app
Tests/run-helper-tests.sh      # helper safety tests (path rules, Trash moves, undo, tamper check)
Tests/run-adminmover-tests.sh  # password-fallback command and quoting tests
```

Scan-only and test modes, from the terminal:

```sh
build/Leftover.app/Contents/MacOS/Leftover --scan /Applications/Foo.app      # list, remove nothing
build/Leftover.app/Contents/MacOS/Leftover --selftest /path/Throwaway.app    # trash + restore round trip
```

## Signing (needed for the helper)

macOS only runs SMAppService daemons from properly signed apps. Without a certificate, `build.sh` signs ad hoc and the helper stays off. Items owned by root (for example apps installed by an installer or the App Store, marked with a lock) are then moved after a single administrator-password prompt, like Finder does. With the helper installed, no password is needed.

1. **For your own Mac:** open Xcode › Settings › Accounts, add your Apple ID, then choose *Manage Certificates › + › Apple Development*. A free account is enough for local use.
2. **To give the app to others:** you need a paid Apple Developer account and a *Developer ID Application* certificate. Then notarize:
   ```sh
   xcrun notarytool store-credentials leftover-notary --apple-id you@example.com --team-id TEAMID
   NOTARY_PROFILE=leftover-notary ./build.sh
   ```

`build.sh` picks the certificate up automatically (Developer ID first, then Apple Development) and bakes its team ID into both binaries. Set `SIGN_IDENTITY` to choose a specific one, or `BUNDLE_ID` to change the identifier.

After the first launch, click **Install Helper** and allow Leftover under System Settings › General › Login Items. Grant **Full Disk Access** as well, so that sandboxed apps' containers can be found and removed.

## How it works

| Part | File |
|---|---|
| Refuses macOS apps: `/System/…` paths and a list of built-in Apple bundle IDs | `Sources/App/AppInspector.swift` |
| Scans ~30 `Library` folders in both domains, plus receipts and the per-user temp/cache folders. Matches the bundle ID or app name at word boundaries; matches that only contain the name start unticked | `Sources/App/RelatedFileFinder.swift` |
| Full Disk Access check: tries to open privacy-protected files | `Sources/App/FullDiskAccess.swift` |
| Moves items with `FileManager.trashItem` where allowed, and asks the helper otherwise. Supports Undo | `Sources/App/Trasher.swift` |
| Registers the helper (SMAppService) and talks to it over XPC | `Sources/App/HelperClient.swift` |
| Root helper | `Sources/Helper/` |
| Removal animation: the icon charges, bursts and scatters into pieces in its own colours, with a system sound. Drawn in code; Reduce Motion gets a plain fade. Preview it without removing anything: `LEFTOVER_DEMO_ZAP=/Applications/Foo.app build/Leftover.app/Contents/MacOS/Leftover` | `Sources/App/ZapAnimation.swift` |

### Helper safety

- **Caller check:** the code-signing requirement (same team ID and identifier) is enforced through the XPC connection's audit token, not a PID lookup.
- **Requests:** a client can only name an item to trash, or a token to restore. The helper picks every destination itself.
- **Allowed locations:** only items inside `/Applications`, `~/Applications`, the `Library` folders listed in `Sources/Shared/SearchLocations.swift`, and installer receipts.
- **Moves:** they use `renameatx_np` with `RENAME_EXCL | RENAME_NOFOLLOW_ANY`, so a move never overwrites anything and a symlink can't redirect it. Directories are opened with `O_NOFOLLOW` and their real location is re-checked with `F_GETPATH`.
- **Undo:** restoring only puts back the exact object that was moved, checked by device and inode in a root-only staging folder. A file swapped in the Trash is refused.
