import Testing
@testable import DispatchApp

@Suite("Foundation smoke tests")
struct FoundationSmokeTests {
    @Test("AppInfo exposes the product name and bundle identifier")
    func appInfoValues() {
        #expect(AppInfo.name == "Dispatch")
        #expect(AppInfo.bundleIdentifier == "com.wizemann.dispatch")
    }
}
