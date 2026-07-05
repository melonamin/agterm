// swift-tools-version:5.9
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendor = "\(packageRoot)/vendor/ghostty"

let package = Package(
    name: "agterm-linux",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(name: "agtermCore", path: "../agtermCore"),
    ],
    targets: [
        .systemLibrary(name: "CGtk", path: "Sources/CGtk", pkgConfig: "libadwaita-1"),
        .executableTarget(
            name: "AgtermLinux",
            dependencies: [
                "CGtk",
                .product(name: "agtermCore", package: "agtermCore"),
            ],
            swiftSettings: [ .unsafeFlags(["-Xcc", "-I\(vendor)/include"]) ],
            linkerSettings: [ .unsafeFlags([
                "-L\(vendor)/lib", "-lghostty", "-lepoxy",
                "-Xlinker", "-rpath", "-Xlinker", "\(vendor)/lib",
            ]) ]
        ),
    ]
)
