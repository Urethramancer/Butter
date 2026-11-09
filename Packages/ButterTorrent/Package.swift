// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "ButterTorrent",
	platforms: [.macOS(.v13), .iOS(.v16)],
	products: [.library(name: "ButterTorrentMetadata", targets: ["ButterTorrentMetadata"])],
	targets: [
		.target(name: "ButterTorrentMetadata"),
		.testTarget(name: "ButterTorrentMetadataTests", dependencies: ["ButterTorrentMetadata"])
	]
)
