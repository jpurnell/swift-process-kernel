// swift-tools-version: 6.2
// legibility:description: A subprocess runner that cannot hang.
import PackageDescription

let package = Package(
    name: "swift-process-kernel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProcessKernel", targets: ["ProcessKernel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "ProcessKernel",
            // Declared as a resource, not excluded: `exclude:` removes the catalogue from the
            // target's sourceFiles, which is how swift-docc-plugin locates it, so doc-lint
            // would pass over an article it never opened.
            resources: [.copy("ProcessKernel.docc")]
        ),
        .testTarget(name: "ProcessKernelTests", dependencies: ["ProcessKernel"]),
    ]
)
