// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickShiftDisplay",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "QuickShiftDisplay", targets: ["QuickShiftDisplay"])],
    targets: [
        .target(name: "InputSafety", linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("CoreFoundation")]),
        .target(name: "QuickShiftCore"),
        .executableTarget(name: "QuickShiftDisplay", dependencies: ["QuickShiftCore", "InputSafety"]),
        .testTarget(name: "QuickShiftCoreTests", dependencies: ["QuickShiftCore"]),
        .testTarget(name: "QuickShiftDisplayTests", dependencies: ["QuickShiftDisplay", "QuickShiftCore", "InputSafety"]),
    ]
)
