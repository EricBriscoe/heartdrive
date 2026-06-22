// swift-tools-version:5.9
import PackageDescription

// Deterministic simulation harness that reproduces the watch->phone WCSession
// failure modes and proves the resilient HeartRateLink wrapper survives them.
// Run: swift run --package-path Tools/LinkSim
let package = Package(
    name: "LinkSim",
    targets: [
        .executableTarget(name: "LinkSim", path: "Sources/LinkSim")
    ]
)
