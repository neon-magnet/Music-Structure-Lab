// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicStructureLab",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // 解析ロジック(プラットフォーム非依存)。今後のテンポ・キー・構造解析もここに追加する。
        .library(name: "MSLCore", targets: ["MSLCore"]),
        // AVFoundation を使った音源デコード。
        .library(name: "MSLAudio", targets: ["MSLAudio"]),
        // SwiftUI アプリ本体。`swift run MusicStructureLab` でも起動できる。
        .executable(name: "MusicStructureLab", targets: ["MusicStructureLab"])
    ],
    targets: [
        .target(name: "MSLCore"),
        .target(name: "MSLAudio", dependencies: ["MSLCore"]),
        .executableTarget(
            name: "MusicStructureLab",
            dependencies: ["MSLCore", "MSLAudio"]
        ),
        .testTarget(name: "MSLCoreTests", dependencies: ["MSLCore"]),
        .testTarget(name: "MSLAudioTests", dependencies: ["MSLAudio", "MSLCore"])
    ]
)
