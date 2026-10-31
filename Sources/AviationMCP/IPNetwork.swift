import Foundation

/// An IPv4 or IPv6 address parsed strictly from its textual form.
enum IPAddress: Hashable, Sendable {
  case ipv4(UInt32)
  case ipv6(UInt128)

  private static let ipv4MappedPrefix: UInt128 = 0xffff

  var bitWidth: Int {
    switch self {
    case .ipv4: 32
    case .ipv6: 128
    }
  }

  /// Parses dotted-quad IPv4 or RFC 4291 IPv6 text, treating IPv4-mapped IPv6 as IPv4.
  init?(_ text: some StringProtocol) {
    if text.contains(":") {
      guard let value = Self.parseIPv6(text) else { return nil }
      self =
        value >> 32 == Self.ipv4MappedPrefix
        ? .ipv4(UInt32(truncatingIfNeeded: value)) : .ipv6(value)
    } else {
      guard let value = Self.parseIPv4(text) else { return nil }
      self = .ipv4(value)
    }
  }

  private static func parseIPv4(_ text: some StringProtocol) -> UInt32? {
    let octets = text.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return nil }
    return octets.reduce(UInt32?(0)) { value, octet in
      guard let value, (1...3).contains(octet.count), octet.allSatisfy(\.isASCII),
        octet.allSatisfy(\.isNumber), let byte = UInt8(octet)
      else { return nil }
      return value << 8 | UInt32(byte)
    }
  }

  private static func parseIPv6(_ text: some StringProtocol) -> UInt128? {
    let halves = text.split(separator: "::", omittingEmptySubsequences: false)
    guard halves.count <= 2,
      let head = words(halves[0], allowsIPv4: halves.count == 1),
      let tail = halves.count == 2 ? words(halves[1], allowsIPv4: true) : []
    else { return nil }
    let elided = 8 - head.count - tail.count
    guard halves.count == 2 ? elided >= 1 : elided == 0 else { return nil }
    return (head + Array(repeating: 0, count: elided) + tail).reduce(0) { $0 << 16 | UInt128($1) }
  }

  private static func words(_ text: some StringProtocol, allowsIPv4: Bool) -> [UInt16]? {
    guard !text.isEmpty else { return [] }
    var groups = text.split(separator: ":", omittingEmptySubsequences: false)
    var embedded: [UInt16] = []
    if allowsIPv4, let last = groups.last, last.contains(".") {
      guard let value = parseIPv4(last) else { return nil }
      embedded = [UInt16(value >> 16), UInt16(truncatingIfNeeded: value)]
      groups.removeLast()
    }
    let parsed = groups.compactMap { group in
      (1...4).contains(group.count) && group.allSatisfy(\.isHexDigit)
        ? UInt16(group, radix: 16) : nil
    }
    return parsed.count == groups.count ? parsed + embedded : nil
  }
}

/// A CIDR block of addresses that share one admission budget.
struct IPNetwork: Hashable, Sendable {
  private static let clientIPv6PrefixLength = 64

  let address: IPAddress
  let prefixLength: Int

  /// The block an individual client controls: one IPv4 address or one IPv6 /64.
  init(client address: IPAddress) {
    switch address {
    case .ipv4: self.init(address, prefixLength: address.bitWidth)
    case .ipv6: self.init(address, prefixLength: Self.clientIPv6PrefixLength)
    }
  }

  /// Parses `address/prefix` notation; a bare address is a single-host block.
  init?(cidr text: some StringProtocol) {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let address = IPAddress(parts[0]) else { return nil }
    let length = parts.count == 2 ? Int(parts[1]) : address.bitWidth
    guard let length, (0...address.bitWidth).contains(length) else { return nil }
    self.init(address, prefixLength: length)
  }

  private init(_ address: IPAddress, prefixLength: Int) {
    self.prefixLength = prefixLength
    self.address = Self.masked(address, prefixLength: prefixLength)
  }

  private static func masked(_ address: IPAddress, prefixLength: Int) -> IPAddress {
    switch address {
    case .ipv4(let value):
      .ipv4(prefixLength == 0 ? 0 : value & (UInt32.max << (32 - prefixLength)))
    case .ipv6(let value):
      .ipv6(prefixLength == 0 ? 0 : value & (UInt128.max << (128 - prefixLength)))
    }
  }

  func contains(_ candidate: IPAddress) -> Bool {
    candidate.bitWidth == address.bitWidth
      && Self.masked(candidate, prefixLength: prefixLength) == address
  }
}
