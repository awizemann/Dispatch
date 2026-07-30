/// Basic app metadata used across the app (and by the foundation smoke test).
/// `nonisolated`: plain constants, safely readable from any isolation domain
/// (e.g. the persistence layer resolves its Application Support directory off-main).
nonisolated enum AppInfo {
    static let name = "Dispatch"
    static let bundleIdentifier = "com.wizemann.dispatch"
}
