import Foundation

// Privileged helper: a launchd daemon registered by the app through SMAppService.
// It runs as root and exposes a single XPC service (see LeftoverHelperProtocol).

let service = HelperService()
let listener = NSXPCListener(machServiceName: BuildConfig.helperLabel)
listener.delegate = service
listener.resume()
RunLoop.main.run()
