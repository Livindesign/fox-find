// swift-tools-version:5.10
import PackageDescription
import Foundation
let runtimeLibrary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/llama/lib").path
let package = Package(
    name: "FoxFind", platforms: [.macOS(.v14)],
    products: [.executable(name: "FoxFind", targets: ["OilFind"]),
               .executable(name: "foxfind-semantic-worker", targets: ["SemanticWorker"]),
               .executable(name: "foxfind-cli", targets: ["oilfind-cli"])],
    targets: [
        .systemLibrary(name: "CLlama"),
        .target(name: "FoxFindSemanticCore"),
        .target(name: "LlamaRuntime", dependencies: ["CLlama", "FoxFindSemanticCore"], linkerSettings: [.unsafeFlags(["-L", runtimeLibrary])]),
        .executableTarget(name: "SemanticWorker", dependencies: ["LlamaRuntime", "FoxFindSemanticCore"]),
        .target(name: "COilFind", publicHeadersPath: "include"),
        .target(name: "OilFindCore", dependencies: ["COilFind"]),
        .target(name: "OilFindApp", dependencies: ["OilFindCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "LocalFindContent", dependencies: ["OilFindApp", "OilFindCore", "FoxFindSemanticCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "OilFind", dependencies: ["OilFindApp", "LocalFindContent"]),
        .executableTarget(name: "oilfind-cli", dependencies: ["OilFindCore"]),
        .testTarget(name: "OilFindCoreTests", dependencies: ["OilFindCore", "COilFind"]),
        .testTarget(name: "OilFindUITests", dependencies: ["OilFindApp", "OilFindCore"]),
        .testTarget(name: "LocalFindContentTests", dependencies: ["LocalFindContent", "OilFindCore", "FoxFindSemanticCore"], resources: [.copy("Fixtures")])
    ], swiftLanguageVersions: [.v5]
)
