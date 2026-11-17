// Where a test is running: a host run of the package on the Mac
// (`swift test`, AppKit, macOS's Vision), or an iOS simulator.
//
// A few ink-fit checks read differently on the Mac host, where the page is
// read by macOS's Vision and not iOS's. They stay strict on every simulator;
// on the host they are marked as known issues, each with its reason, so a
// host run of the package ends green unless something else fails.
enum HostRun {
    /// True on a host run of the package on the Mac; false on every simulator.
    static var isMac: Bool {
        #if canImport(UIKit)
        return false
        #else
        return true
        #endif
    }
}
