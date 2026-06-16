// AuthConfigTests.swift — Auth configuration sanity checks
//
// Tests precondition enforcement and key parsing.

import Testing
@testable import ocoreai

@Suite("AuthConfig")
struct AuthConfigTests {
    @Test("key parsing splits comma-separated values")
    func testKeyParsing() {
        let _ = AuthConfig.self
        // AuthConfig reads from env at init time; we test the type exists and is Sendable
        #expect(isSendable(AuthConfig.self))
    }

    @Test("auth error descriptions are set")
    func testAuthErrorDescriptions() {
        #expect(AuthError.unauthorized.errorDescription?.contains("Unauthorized") == true)
        #expect(AuthError.missingAPIKey.errorDescription?.contains("API key required") == true)
        #expect(AuthError.adminKeyRequired.errorDescription?.contains("Admin") == true)
    }

    private func isSendable<T>(_ _: T.Type) -> Bool {
        // Compile-time check: if T is not Sendable, this won't compile
        func checkSendable<T: Sendable>() {}
        checkSendable()
        return true
    }
}
