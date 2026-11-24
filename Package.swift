// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WiFiDoctor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WiFiDoctor", path: "Sources/WiFiDoctor"),
        .testTarget(name: "WiFiDoctorTests", dependencies: ["WiFiDoctor"], path: "Tests/WiFiDoctorTests"),
    ]
)
