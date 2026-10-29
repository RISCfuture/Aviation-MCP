import Foundation

struct TerrainRelease: Sendable {
  static let copernicus2021 = Self(
    name: "Copernicus DEM 2021 AWS public",
    glo30Checksum: "10604e3052c98a09e9216f1a8f0a555a04148419757575f783d4937fd44316dc",
    glo90Checksum: "e5a5efe088e70506bc1007d22006bdcb09b0ec03177b62f9652363c13f49ed97")

  let name: String
  let glo30Checksum: String
  let glo90Checksum: String
}
