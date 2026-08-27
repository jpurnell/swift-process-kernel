// swift-tools-version: 6.2
// legibility:description: A subprocess runner that cannot hang.
import PackageDescription

let package = Package(
    name: "swift-process-kernel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProcessKernel", targets: ["ProcessKernel"]),
    ],
    targets: [
        .target(name: "ProcessKernel"),
        .testTarget(name: "ProcessKernelTests", dependencies: ["ProcessKernel"]),
    ]
)
