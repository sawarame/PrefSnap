// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Command Line Tools 単体環境（Swift 6.4+ の swiftbuild）でも
// 引数なしの `swift test` で Swift Testing マクロが解決できるよう、存在時のみプラグインを指定する。
let cltTestingMacroPlugin = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
var testSwiftSettings: [SwiftSetting] = []
if FileManager.default.fileExists(atPath: cltTestingMacroPlugin) {
    testSwiftSettings.append(.unsafeFlags(["-load-plugin-library", cltTestingMacroPlugin]))
}

let package = Package(
    name: "PrefSnap",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PrefSnapCore",
            targets: ["PrefSnapCore"]
        ),
        .executable(
            name: "PrefSnap",
            targets: ["PrefSnap"]
        )
    ],
    targets: [
        .target(
            name: "PrefSnapCore",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "PrefSnap",
            dependencies: ["PrefSnapCore"]
        ),
        .testTarget(
            name: "PrefSnapCoreTests",
            dependencies: ["PrefSnapCore"],
            swiftSettings: testSwiftSettings
        )
    ]
)
