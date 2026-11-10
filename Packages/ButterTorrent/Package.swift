// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "ButterTorrent",
	platforms: [.macOS(.v13), .iOS(.v16)],
	products: [
		.library(name: "ButterTorrentMetadata", targets: ["ButterTorrentMetadata"]),
		.library(name: "ButterTorrentNetworking", targets: ["ButterTorrentNetworking"]),
		.library(name: "ButterTorrentStorage", targets: ["ButterTorrentStorage"]),
		.library(name: "ButterTorrentEngine", targets: ["ButterTorrentEngine"])
	],
	targets: [
		.target(name: "ButterTorrentMetadata"),
		.testTarget(name: "ButterTorrentMetadataTests", dependencies: ["ButterTorrentMetadata"]),
		.target(name: "ButterTorrentNetworking", dependencies: ["ButterTorrentMetadata"]),
		.testTarget(name: "ButterTorrentNetworkingTests", dependencies: ["ButterTorrentNetworking", "ButterTorrentMetadata"]),
		.target(name: "ButterTorrentStorage", dependencies: ["ButterTorrentMetadata"]),
		.testTarget(name: "ButterTorrentStorageTests", dependencies: ["ButterTorrentStorage", "ButterTorrentMetadata"]),
		.target(name: "ButterTorrentEngine", dependencies: ["ButterTorrentMetadata", "ButterTorrentNetworking", "ButterTorrentStorage"]),
		.testTarget(name: "ButterTorrentEngineTests", dependencies: ["ButterTorrentEngine"])
	]
)
