import Foundation

@main struct SpeechModelsSmoke {
    @MainActor static func main() async throws {
        guard #available(macOS 26.0, *) else { throw problem("macOS 26 required") }
        let chinese = await SpeechModelAssets.state(for: "zh_CN")
        precondition(chinese == .installed, "This smoke test expects the existing local Chinese model")
        var requestedDownload = false
        try await SpeechModelAssets.download("zh_CN") { _ in requestedDownload = true }
        precondition(!requestedDownload, "An installed model must not start a download")
        let unsupported = await SpeechModelAssets.state(for: "xx_XX")
        precondition(unsupported == .unsupported)
        print("PASS: installed Chinese detected, repeated download skipped, unsupported locale rejected")
        for locale in ["zh_CN", "zh_TW", "en_US", "yue_CN"] {
            print("\(locale): \(await SpeechModelAssets.state(for: locale))")
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--download" {
            let locale = CommandLine.arguments[2]
            try await SpeechModelAssets.download(locale) { _ in print("Download requested: \(locale)") }
            let state = await SpeechModelAssets.state(for: locale)
            precondition(state == .installed)
            print("PASS: model downloaded and independently rechecked as installed: \(locale)")
        }
    }
}
