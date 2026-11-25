import Foundation
import Testing
@testable import TunnelMasterCore

struct SystemProxyTests {
    private let installed: [String: Any] = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 17880,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 17880,
        "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 17880,
        "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
    ]

    @Test func restoresPriorProxyGroupsAndRemovesPreviouslyAbsentFields() throws {
        let previous: [String: Any] = [
            "HTTPEnable": 0, "HTTPProxy": "previous.example", "HTTPPort": 9090,
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example.test/proxy.pac",
            "ExceptionsList": ["*.local"]
        ]
        let journal = try ProxyJournal(serviceID: "previous", port: 17880, previousEnabled: true, previous: previous)
        var current = previous
        current.merge(installed) { _, installedValue in installedValue }

        let restored = try journal.restoration(current: current, enabled: true)
        #expect((restored.values as NSDictionary) == (previous as NSDictionary))
        #expect(restored.enabled)
        #expect(restored.changed)
    }

    @Test func preservesThirdPartyProxyOverridesAndNewPACURL() throws {
        let previous: [String: Any] = [
            "HTTPEnable": 0, "HTTPProxy": "previous.example", "HTTPPort": 9090,
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://old.example/proxy.pac"
        ]
        let journal = try ProxyJournal(serviceID: "previous", port: 17880, previousEnabled: false, previous: previous)
        var current = previous
        current.merge(installed) { _, installedValue in installedValue }
        current["HTTPProxy"] = "other.example"
        current["HTTPPort"] = 9999
        current["ProxyAutoConfigURLString"] = "https://new.example/proxy.pac"

        let restored = try journal.restoration(current: current, enabled: true)
        #expect((restored.values["HTTPProxy"] as? String) == "other.example")
        #expect((restored.values["HTTPPort"] as? Int) == 9999)
        #expect((restored.values["ProxyAutoConfigEnable"] as? Int) == 0)
        #expect((restored.values["ProxyAutoConfigURLString"] as? String) == "https://new.example/proxy.pac")
        #expect(restored.values["HTTPSProxy"] == nil)
        #expect(restored.values["SOCKSProxy"] == nil)
        #expect(restored.enabled)
    }

    @Test func replayingRestorationIsIdempotentAfterCommit() throws {
        let previous: [String: Any] = ["ExceptionsList": ["localhost"]]
        let journal = try ProxyJournal(serviceID: "previous", port: 17880, previousEnabled: false, previous: previous)
        var current = previous
        current.merge(installed) { _, installedValue in installedValue }
        let first = try journal.restoration(current: current, enabled: true)
        let second = try journal.restoration(current: first.values, enabled: first.enabled)
        #expect((second.values as NSDictionary) == (previous as NSDictionary))
        #expect(!second.enabled)
        #expect(!second.changed)
    }
}
