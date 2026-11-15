// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DriveOffloader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DriveOffloader", targets: ["DriveOffloader"])
    ],
    targets: [
        .executableTarget(
            name: "DriveOffloader",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices")
            ]
        )
    ]
)
