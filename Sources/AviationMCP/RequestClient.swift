/// The admitted client's network (one IPv4 address or IPv6 /64), bound while its `/mcp` request
/// runs so shared resources can give each client a fair share.
enum RequestClient {
  @TaskLocal static var key: IPNetwork?
}
