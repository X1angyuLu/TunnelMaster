import Foundation
import Testing
import TunnelMasterCore

struct RuleConfigurationTests {
    private static let privateKey = Data(repeating: 1, count: 32).base64EncodedString()
    private static let publicKey = Data(repeating: 2, count: 32).base64EncodedString()
    private static let presharedKey = Data(repeating: 3, count: 32).base64EncodedString()

    private var profileText: String {
        """
        # Fixture only
        [Interface]
        PrivateKey = \(Self.privateKey)
        Address = 192.0.2.2/32, 2001:db8:1::2/128
        DNS = 192.0.2.53, 2001:db8:1::53, example.net
        MTU = 1380

        [Peer]
        PublicKey = \(Self.publicKey)
        PresharedKey = \(Self.presharedKey)
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = [2001:db8:2::1]:51820
        PersistentKeepalive = 25 # optional keepalive
        """
    }

    @Test func profileConfigPreservesKeysAddressesAndEndpoint() throws {
        let profile = try WireGuardProfile.parse(profileText.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(profile.endpointHost == "2001:db8:2::1")
        #expect(profile.endpointPort == 51820)

        let rules = try DomainRules.parse(direct: "", proxy: "", china: false)
        let generated = try MihomoConfiguration.make(profile: profile, rules: rules, port: 17890)
        #expect(!String(decoding: generated, as: UTF8.self).contains(#"\/"#))
        let configuration = try decode(generated)
        let routing = try #require(configuration["rules"] as? [String])
        #expect(routing.last == "MATCH,WireGuard")
        let outbounds = try #require(configuration["proxies"] as? [[String: Any]])
        let outbound = try #require(outbounds.first)
        #expect(outbound["server"] as? String == "2001:db8:2::1")
        #expect(outbound["port"] as? Int == 51820)
        #expect(outbound["private-key"] as? String == Self.privateKey)
        #expect(outbound["public-key"] as? String == Self.publicKey)
        #expect(outbound["pre-shared-key"] as? String == Self.presharedKey)
        #expect(outbound["ip"] as? String == "192.0.2.2")
        #expect(outbound["ipv6"] as? String == "2001:db8:1::2")
        #expect(outbound["allowed-ips"] as? [String] == ["0.0.0.0/0", "::/0"])
        #expect(outbound["dns"] as? [String] == ["192.0.2.53", "2001:db8:1::53"])
        #expect(outbound["remote-dns-resolve"] as? Bool == true)
        #expect(outbound["persistent-keepalive"] as? Int == 25)
        #expect(outbound["mtu"] as? Int == 1380)
    }

    @Test func profileRejectsMultiplePeersAndMalformedSecrets() {
        #expect(throws: (any Error).self) {
            try WireGuardProfile.parse(profileText + "\n[Peer]\n")
        }
        let invalidSecret = "sensitive-invalid-key"
        let input = profileText.replacingOccurrences(of: Self.privateKey, with: invalidSecret)
        do {
            _ = try WireGuardProfile.parse(input)
            Issue.record("Invalid key material was accepted")
        } catch {
            #expect(!error.localizedDescription.contains(invalidSecret))
        }
        #expect(throws: (any Error).self) {
            try WireGuardProfile.parse(profileText.replacingOccurrences(of: "]:51820", with: "]:65536"))
        }
    }

    @Test func rulesNormalizeAndUseFirstMatchPriority() throws {
        let profile = try WireGuardProfile.parse(profileText)
        let rules = try DomainRules.parse(
            direct: "  *.EXAMPLE.CN, .example.cn.\nservice.cn. ",
            proxy: "api.example.cn",
            china: true
        )
        #expect(rules.direct == ["example.cn", "service.cn"])
        let configuration = try decode(MihomoConfiguration.make(
            profile: profile,
            rules: rules,
            port: 17890,
            chinaIPDatabasePath: "/tmp/geoip.metadb"
        ))
        let emittedRules = try #require(configuration["rules"] as? [String])
        #expect(Array(emittedRules.prefix(3)) == [
            "DOMAIN-SUFFIX,api.example.cn,WireGuard",
            "DOMAIN-SUFFIX,example.cn,DIRECT",
            "DOMAIN-SUFFIX,service.cn,DIRECT"
        ])
        #expect(emittedRules.contains("IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"))
        #expect(Array(emittedRules.suffix(2)) == ["GEOIP,CN,DIRECT", "MATCH,WireGuard"])
        #expect(configuration["bind-address"] as? String == "127.0.0.1")
        #expect(configuration["allow-lan"] as? Bool == false)
        #expect(configuration["geo-auto-update"] as? Bool == false)
        #expect(configuration["external-controller"] == nil)
    }

    @Test func noGeoIPRuleWithoutStagedDatabase() throws {
        let profile = try WireGuardProfile.parse(profileText)
        let rules = try DomainRules.parse(direct: "example.cn", proxy: "", china: true)
        let configuration = try decode(MihomoConfiguration.make(profile: profile, rules: rules, port: 17890))
        let emittedRules = try #require(configuration["rules"] as? [String])
        #expect(!emittedRules.contains("GEOIP,CN,DIRECT"))
        #expect(emittedRules.last == "MATCH,WireGuard")
    }

    @Test func directFallbackOnlyChangesUnmatchedRouting() throws {
        let profile = try WireGuardProfile.parse(profileText)
        let defaultRules = try DomainRules.parse(direct: "example.cn", proxy: "api.example.cn", china: true)
        let directRules = try DomainRules.parse(
            direct: "example.cn", proxy: "api.example.cn", china: true, fallback: .direct
        )
        let defaultConfig = try decode(MihomoConfiguration.make(
            profile: profile, rules: defaultRules, port: 17890, chinaIPDatabasePath: "/tmp/geoip.metadb"
        ))
        let directConfig = try decode(MihomoConfiguration.make(
            profile: profile, rules: directRules, port: 17890, chinaIPDatabasePath: "/tmp/geoip.metadb"
        ))
        let oldRouting = try #require(defaultConfig["rules"] as? [String])
        let newRouting = try #require(directConfig["rules"] as? [String])
        #expect(Array(oldRouting.dropLast()) == Array(newRouting.dropLast()))
        #expect(oldRouting.last == "MATCH,WireGuard")
        #expect(newRouting.last == "MATCH,DIRECT")
    }

    @Test func legacyRulesDecodeWithProxyFallbackAndExplicitFallbackRoundTrips() throws {
        let legacy = Data(#"{"direct":["example.cn"],"proxy":["example.com"],"useChinaIPRules":true}"#.utf8)
        let decoded = try JSONDecoder().decode(DomainRules.self, from: legacy)
        #expect(decoded == DomainRules(direct: ["example.cn"], proxy: ["example.com"], useChinaIPRules: true))

        let directRules = DomainRules(direct: [], proxy: ["example.com"], useChinaIPRules: false, fallback: .direct)
        let saved = try JSONEncoder().encode(directRules)
        #expect(try JSONDecoder().decode(DomainRules.self, from: saved) == directRules)
    }

    @Test func directFallbackSeparatesTunnelDomainDNSFromSystemDNS() throws {
        let configured = try WireGuardProfile.parse(profileText)
        let rules = try DomainRules.parse(direct: "example.cn", proxy: "openai.com\nclaude.ai", china: false,
                                          fallback: .direct)
        let configuration = try decode(MihomoConfiguration.make(profile: configured, rules: rules, port: 17890))
        let dns = try #require(configuration["dns"] as? [String: Any])
        let policy = try #require(dns["nameserver-policy"] as? [String: [String]])
        #expect(dns["listen"] as? String == "")
        #expect(dns["proxy-server-nameserver"] as? [String] == ["system"])
        #expect(dns["direct-nameserver"] as? [String] == ["system"])
        #expect(policy["+.openai.com"] == ["udp://192.0.2.53:53#WireGuard", "udp://[2001:db8:1::53]:53#WireGuard"])
        #expect(policy["+.claude.ai"] == policy["+.openai.com"])
        #expect(policy["+.example.cn"] == nil)

        let withoutDNS = try WireGuardProfile.parse(profileText.replacingOccurrences(
            of: "DNS = 192.0.2.53, 2001:db8:1::53, example.net\n", with: ""
        ))
        let fallbackConfig = try decode(MihomoConfiguration.make(profile: withoutDNS, rules: rules, port: 17890))
        let proxy = try #require((fallbackConfig["proxies"] as? [[String: Any]])?.first)
        #expect(proxy["dns"] as? [String] == ["https://1.1.1.1/dns-query"])
        #expect(proxy["remote-dns-resolve"] as? Bool == true)
    }

    @Test func rejectsURLsAndRulesInjectedThroughSavedPreferences() throws {
        #expect(throws: (any Error).self) {
            try DomainRules.parse(direct: "https://example.com/path", proxy: "", china: false)
        }
        let profile = try WireGuardProfile.parse(profileText)
        let unsafe = DomainRules(direct: ["example.com,DIRECT\nMATCH,REJECT"], proxy: [], useChinaIPRules: false)
        #expect(throws: (any Error).self) {
            try MihomoConfiguration.make(profile: profile, rules: unsafe, port: 17890)
        }
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }
}
