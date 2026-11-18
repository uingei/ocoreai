// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// ChildProcessEnvTests — both launcher-environment policies to exact values. The scrub
// mechanism shipped before any gate read it; this suite is the red it owed.
import Foundation
import Testing
@_spi(ChildProcessEnv) import ocoreai

@Suite("ChildProcessEnv")
struct ChildProcessEnvTests {

    @Test("sanitized passes the allowlist byte-for-byte and drops everything else")
    func whitelist() {
        let out = ChildProcessEnv.sanitized(from: [
            "PATH": "/usr/bin", "HOME": "/Users/tester", "OCOREAI_PORT": "8231",
            "SOME_PROXY_URL": "http://corp:3128", "AWS_SECRET_ACCESS_KEY": "ak",
        ])
        #expect(out == ["PATH": "/usr/bin", "HOME": "/Users/tester", "OCOREAI_PORT": "8231"])
    }

    @Test("removingSecrets drops exactly the four named secrets and keeps the caller's rest")
    func secretsOnly() {
        let out = ChildProcessEnv.removingSecrets(from: [
            "OCOREAI_API_KEYS": "sk", "OCOREAI_ADMIN_KEYS": "sk", "OCOREAI_BEARER": "sk",
            "OCOREAI_TOKEN": "sk", "ANTHROPIC_API_KEY": "user-key", "PATH": "/usr/bin",
        ])
        #expect(out == ["ANTHROPIC_API_KEY": "user-key", "PATH": "/usr/bin"])
    }
}
