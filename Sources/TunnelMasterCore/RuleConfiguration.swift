import Darwin
import Foundation

public struct WireGuardProfile: Equatable, Sendable {
    public let endpointHost: String
    public let endpointPort: Int

    fileprivate let ipv4Address: String?
    fileprivate let ipv6Address: String?
    fileprivate let privateKey: String
    fileprivate let publicKey: String
    fileprivate let presharedKey: String?
    fileprivate let allowedIPs: [String]
    fileprivate let dnsServers: [String]
    fileprivate let keepalive: Int?
    fileprivate let mtu: Int?

    public static func parse(_ input: String) throws -> Self {
        var interface: [String: String]?
        var peer: [String: String]?
        var inPeer = false

        for rawLine in input.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            .split(whereSeparator: \.isNewline) {
            let line = String(rawLine.prefix(while: { $0 != "#" }))
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            switch line.lowercased() {
            case "[interface]":
                guard interface == nil else { throw RuleConfigurationError.interfaceCount }
                interface = [:]
                inPeer = false
            case "[peer]":
                guard peer == nil else { throw RuleConfigurationError.peerCount }
                peer = [:]
                inPeer = true
            default:
                let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count == 2, !fields[0].isEmpty,
                      inPeer || interface != nil else {
                    throw RuleConfigurationError.malformedProfile
                }
                let name = fields[0].lowercased()
                if inPeer {
                    guard peer?[name] == nil else { throw RuleConfigurationError.malformedProfile }
                    peer?[name] = fields[1]
                } else {
                    guard interface?[name] == nil else { throw RuleConfigurationError.malformedProfile }
                    interface?[name] = fields[1]
                }
            }
        }

        guard let interface else { throw RuleConfigurationError.interfaceCount }
        guard let peer else { throw RuleConfigurationError.peerCount }
        let addresses = try commaSeparated(interface["address"]).map(AddressPrefix.parse)
        let ipv4Addresses = addresses.filter { $0.family == .ipv4 }
        let ipv6Addresses = addresses.filter { $0.family == .ipv6 }
        guard !addresses.isEmpty, ipv4Addresses.count <= 1, ipv6Addresses.count <= 1 else {
            throw RuleConfigurationError.interfaceAddress
        }

        let allowedIPs = try commaSeparated(peer["allowedips"]).map(AddressPrefix.parse)
        guard !allowedIPs.isEmpty else { throw RuleConfigurationError.missingAllowedIPs }
        let (host, port) = try parseEndpoint(peer["endpoint"])
        let privateKey = try parseKey(interface["privatekey"])
        let publicKey = try parseKey(peer["publickey"])
        let presharedKey = try peer["presharedkey"].map { try parseKey($0) }
        let dnsServers = commaSeparated(interface["dns"]).filter { IPFamily.of($0) != nil }
        let keepalive = try parseInteger(peer["persistentkeepalive"], range: 0...65535)
        let mtu = try parseInteger(interface["mtu"], range: 576...65535)

        return Self(
            endpointHost: host,
            endpointPort: port,
            ipv4Address: ipv4Addresses.first?.address,
            ipv6Address: ipv6Addresses.first?.address,
            privateKey: privateKey,
            publicKey: publicKey,
            presharedKey: presharedKey,
            allowedIPs: allowedIPs.map(\.cidr),
            dnsServers: dnsServers,
            keepalive: keepalive,
            mtu: mtu
        )
    }

    private static func parseEndpoint(_ value: String?) throws -> (String, Int) {
        guard let value else { throw RuleConfigurationError.invalidEndpoint }
        let host: String
        let portText: Substring
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { throw RuleConfigurationError.invalidEndpoint }
            host = String(value[value.index(after: value.startIndex)..<end])
            let suffix = value[value.index(after: end)...]
            guard IPFamily.of(host) == .ipv6, suffix.hasPrefix(":") else {
                throw RuleConfigurationError.invalidEndpoint
            }
            portText = suffix.dropFirst()
        } else {
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw RuleConfigurationError.invalidEndpoint }
            host = String(fields[0])
            guard IPFamily.of(host) == .ipv4 || isDNSName(host, allowsSingleLabel: true) else {
                throw RuleConfigurationError.invalidEndpoint
            }
            portText = fields[1]
        }
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw RuleConfigurationError.invalidEndpoint
        }
        return (host, port)
    }

    private static func parseKey(_ value: String?) throws -> String {
        guard let value, let key = Data(base64Encoded: value), key.count == 32,
              key.base64EncodedString() == value else {
            throw RuleConfigurationError.invalidKey
        }
        return value
    }

    private static func parseInteger(_ value: String?, range: ClosedRange<Int>) throws -> Int? {
        guard let value else { return nil }
        if value.lowercased() == "off", range.lowerBound == 0 { return 0 }
        guard let integer = Int(value), range.contains(integer) else {
            throw RuleConfigurationError.malformedProfile
        }
        return integer
    }
}

public struct DomainRules: Codable, Equatable, Sendable {
    public enum Fallback: String, Codable, CaseIterable, Sendable {
        case proxy, direct
    }

    public let direct: [String]
    public let proxy: [String]
    public let useChinaIPRules: Bool
    public let fallback: Fallback

    public init(direct: [String], proxy: [String], useChinaIPRules: Bool, fallback: Fallback = .proxy) {
        self.direct = direct
        self.proxy = proxy
        self.useChinaIPRules = useChinaIPRules
        self.fallback = fallback
    }

    private enum CodingKeys: String, CodingKey {
        case direct, proxy, useChinaIPRules, fallback
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            direct: try values.decode([String].self, forKey: .direct),
            proxy: try values.decode([String].self, forKey: .proxy),
            useChinaIPRules: try values.decode(Bool.self, forKey: .useChinaIPRules),
            fallback: try values.decodeIfPresent(Fallback.self, forKey: .fallback) ?? .proxy
        )
    }

    public static func parse(direct: String, proxy: String, china: Bool, fallback: Fallback = .proxy) throws -> Self {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，"))
        return try Self(
            direct: normalize(direct.components(separatedBy: separators).filter { !$0.isEmpty }),
            proxy: normalize(proxy.components(separatedBy: separators).filter { !$0.isEmpty }),
            useChinaIPRules: china,
            fallback: fallback
        )
    }

    fileprivate static func normalize(_ values: [String]) throws -> [String] {
        var seen: Set<String> = []
        return try values.compactMap { value in
            var domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if domain.hasPrefix("*.") {
                domain.removeFirst(2)
            } else if domain.hasPrefix(".") {
                domain.removeFirst()
            }
            if domain.hasSuffix(".") { domain.removeLast() }
            guard IPFamily.of(domain) == nil, isDNSName(domain, allowsSingleLabel: false) else {
                throw RuleConfigurationError.invalidDomain
            }
            return seen.insert(domain).inserted ? domain : nil
        }
    }
}

public enum MihomoConfiguration {
    public static func make(
        profile: WireGuardProfile,
        rules: DomainRules,
        port: Int,
        chinaIPDatabasePath: String? = nil
    ) throws -> Data {
        guard (1...65535).contains(port) else { throw RuleConfigurationError.invalidLocalPort }

        let outboundName = "WireGuard"
        var outbound: [String: Any] = [
            "name": outboundName,
            "type": "wireguard",
            "server": profile.endpointHost,
            "port": profile.endpointPort,
            "private-key": profile.privateKey,
            "public-key": profile.publicKey,
            "allowed-ips": profile.allowedIPs,
            "udp": true,
            "ip-version": profile.ipv4Address == nil ? "ipv6" : "ipv4-prefer"
        ]
        if let address = profile.ipv4Address { outbound["ip"] = address }
        if let address = profile.ipv6Address { outbound["ipv6"] = address }
        if let key = profile.presharedKey { outbound["pre-shared-key"] = key }
        if let keepalive = profile.keepalive { outbound["persistent-keepalive"] = keepalive }
        if let mtu = profile.mtu { outbound["mtu"] = mtu }

        // Validate loaded preferences too, since they may have been edited outside the app.
        let proxyDomains = try DomainRules.normalize(rules.proxy)
        let directDomains = try DomainRules.normalize(rules.direct)
        let splitDNS = rules.fallback == .direct && !proxyDomains.isEmpty
        var wireGuardResolvers = profile.dnsServers
        if splitDNS, wireGuardResolvers.isEmpty {
            // The default encrypted resolver must itself be reachable inside the imported peer's routes.
            if profile.ipv4Address != nil, profile.allowedIPs.contains("0.0.0.0/0") {
                wireGuardResolvers = ["https://1.1.1.1/dns-query"]
            } else if profile.ipv6Address != nil, profile.allowedIPs.contains("::/0") {
                wireGuardResolvers = ["https://[2606:4700:4700::1111]/dns-query"]
            }
        }
        if !wireGuardResolvers.isEmpty {
            outbound["remote-dns-resolve"] = true
            outbound["dns"] = wireGuardResolvers
        }

        var routing = proxyDomains.map { "DOMAIN-SUFFIX,\($0),\(outboundName)" }
        routing += directDomains.map { "DOMAIN-SUFFIX,\($0),DIRECT" }
        routing += [
            "DOMAIN,localhost,DIRECT",
            "DOMAIN-SUFFIX,local,DIRECT",
            "DOMAIN-SUFFIX,home.arpa,DIRECT",
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR6,::1/128,DIRECT,no-resolve",
            "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
            "IP-CIDR6,fe80::/10,DIRECT,no-resolve"
        ]
        // The caller stages the data under Mihomo's home as Country.mmdb or geoip.metadb.
        if rules.useChinaIPRules, let chinaIPDatabasePath, !chinaIPDatabasePath.isEmpty {
            routing.append("GEOIP,CN,DIRECT")
        }
        routing.append(rules.fallback == .proxy ? "MATCH,\(outboundName)" : "MATCH,DIRECT")

        var configuration: [String: Any] = [
            "mixed-port": port,
            "allow-lan": false,
            "bind-address": "127.0.0.1",
            "mode": "rule",
            "log-level": "silent",
            "geodata-mode": false,
            "geo-auto-update": false,
            "ipv6": profile.ipv6Address != nil,
            "proxies": [outbound],
            "rules": routing
        ]
        if splitDNS, !wireGuardResolvers.isEmpty {
            let throughTunnel = wireGuardResolvers.map { server in
                switch IPFamily.of(server) {
                case .ipv4: "udp://\(server):53#\(outboundName)"
                case .ipv6: "udp://[\(server)]:53#\(outboundName)"
                case nil: "\(server)#\(outboundName)"
                }
            }
            configuration["dns"] = [
                "enable": true,
                "enhanced-mode": "redir-host",
                "listen": "",
                "ipv6": profile.ipv6Address != nil,
                "nameserver": ["system"],
                "direct-nameserver": ["system"],
                "proxy-server-nameserver": ["system"],
                "nameserver-policy": Dictionary(uniqueKeysWithValues: proxyDomains.map { ("+.\($0)", throughTunnel) })
            ] as [String: Any]
        }
        // Mihomo parses this as YAML, whose double-quoted strings reject JSON's escaped slash.
        return try JSONSerialization.data(
            withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}

private enum RuleConfigurationError: LocalizedError {
    case malformedProfile
    case interfaceCount
    case peerCount
    case interfaceAddress
    case invalidAddress
    case missingAllowedIPs
    case invalidEndpoint
    case invalidKey
    case invalidDomain
    case invalidLocalPort

    var errorDescription: String? {
        switch self {
        case .malformedProfile: return "WireGuard 配置格式有误。"
        case .interfaceCount: return "WireGuard 配置需要一个 Interface 段。"
        case .peerCount: return "分流模式需要恰好一个 WireGuard Peer。"
        case .interfaceAddress: return "配置需要隧道地址，并且每种 IP 类型最多有一个地址。"
        case .invalidAddress: return "WireGuard 配置里有无效的 IP 地址或网段。"
        case .missingAllowedIPs: return "WireGuard 配置缺少 AllowedIPs。"
        case .invalidEndpoint: return "WireGuard 服务器地址或端口有误。"
        case .invalidKey: return "WireGuard 配置的密钥格式有误。"
        case .invalidDomain: return "请输入域名或域名后缀（如 example.com），并去掉协议、端口和路径。"
        case .invalidLocalPort: return "本机代理端口无效。"
        }
    }
}

private enum IPFamily {
    case ipv4
    case ipv6

    static func of(_ value: String) -> Self? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 { return .ipv4 }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 { return .ipv6 }
        return nil
    }
}

private struct AddressPrefix {
    let address: String
    let family: IPFamily
    let cidr: String

    static func parse(_ value: String) throws -> Self {
        let fields = value.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = fields.first, fields.count <= 2 else {
            throw RuleConfigurationError.invalidAddress
        }
        let address = String(first)
        guard let family = IPFamily.of(address) else { throw RuleConfigurationError.invalidAddress }
        let length = family == .ipv4 ? 32 : 128
        let prefix = fields.count == 2 ? Int(fields[1]) : length
        guard let prefix, (0...length).contains(prefix) else {
            throw RuleConfigurationError.invalidAddress
        }
        return Self(address: address, family: family, cidr: "\(address)/\(prefix)")
    }
}

private func commaSeparated(_ value: String?) -> [String] {
    value?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
}

private func isDNSName(_ value: String, allowsSingleLabel: Bool) -> Bool {
    let name = value.hasSuffix(".") ? value.dropLast() : value[...]
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    guard name.utf8.count <= 253, allowsSingleLabel || labels.count >= 2 else { return false }
    return labels.allSatisfy { label in
        (1...63).contains(label.utf8.count) &&
            label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}
