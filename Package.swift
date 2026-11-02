// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "e15287985625dbf544a343df679436789ffb03fb", traits: ["Diarizer"])],
    targets: [.executableTarget(name: "MeetingRecorder", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)])]
)
