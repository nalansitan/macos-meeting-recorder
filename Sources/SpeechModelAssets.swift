import Foundation
import Speech

enum CaptionModelState: Equatable {
    case checking, installed, missing, unsupported

    var message: String {
        switch self {
        case .checking: return "正在检查离线模型……"
        case .installed: return "已就绪 · 已安装，可离线识别"
        case .missing: return "尚未安装此语言的离线模型"
        case .unsupported: return "此系统或设备不支持该语言的离线识别"
        }
    }
}

@available(macOS 26.0, *)
enum SpeechModelAssets {
    static func state(for identifier: String) async -> CaptionModelState {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            return .unsupported
        }
        // AssetInventory.status may say 'supported' until this app reserves the
        // locale, even when another app already installed it. This read is shared.
        return await SpeechTranscriber.installedLocales.contains(locale) ? .installed : .missing
    }

    // This is the only download path. Recording never calls it.
    @MainActor static func download(_ identifier: String, progress: (Progress) -> Void) async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw problem("此 Mac 不支持所选语言的系统离线识别")
        }
        // Recheck immediately before preparing a request; another app may have installed it.
        if await SpeechTranscriber.installedLocales.contains(locale) { return }
        let ownsReservation = try await AssetInventory.reserve(locale: locale)
        do {
            let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                progress(request.progress)
                try await request.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: [module]) == .installed,
                  await SpeechTranscriber.installedLocales.contains(locale) else {
                throw problem("模型尚未完成安装，请稍后刷新状态或重试。")
            }
        } catch {
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
        // Keep successful preparations reserved for this app across launches.
        // Releasing here unsubscribes the app and may make installedLocales drop
        // the language again immediately after an otherwise successful download.
    }
}
