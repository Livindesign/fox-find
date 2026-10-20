// swift-tools-version:5.10
import PackageDescription
import Foundation
let runtimeLibrary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/llama/lib").path
let package = Package(
    name: "FoxFind", platforms: [.macOS(.v14)],
    products: [.executable(name: "FoxFind", targets: ["FoxFind"]),
               .executable(name: "foxfind-semantic-worker", targets: ["SemanticWorker"]),
               .executable(name: "foxfind-cli", targets: ["foxfind-cli"])],
    targets: [
        .systemLibrary(name: "CLlama"),
        .target(name: "FoxFindSemanticCore"),
        .target(name: "LlamaRuntime", dependencies: ["CLlama", "FoxFindSemanticCore"], linkerSettings: [.unsafeFlags(["-L", runtimeLibrary])]),
        .executableTarget(name: "SemanticWorker", dependencies: ["LlamaRuntime", "FoxFindSemanticCore"]),
        .target(name: "CFoxFind", publicHeadersPath: "include"),
        .target(name: "FoxFindCore", dependencies: ["CFoxFind"]),
        .target(name: "FoxFindApp", dependencies: ["FoxFindCore"], resources: [.copy("Resources/Icons"), .copy("Resources/Guide"), .copy("Resources/TopicIcons")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "FoxFindContent", dependencies: ["FoxFindApp", "FoxFindCore", "FoxFindSemanticCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "FoxFind", dependencies: ["FoxFindApp", "FoxFindContent"]),
        .executableTarget(name: "foxfind-cli", dependencies: ["FoxFindCore"]),
        .testTarget(name: "FoxFindCoreTests", dependencies: ["FoxFindCore", "CFoxFind"]),
        .testTarget(name: "FoxFindUITests", dependencies: ["FoxFindApp", "FoxFindCore"]),
        .testTarget(name: "FoxFindContentTests", dependencies: ["FoxFindContent", "FoxFindCore", "FoxFindSemanticCore"], resources: [.copy("Fixtures")])
    ], swiftLanguageVersions: [.v5]
)
