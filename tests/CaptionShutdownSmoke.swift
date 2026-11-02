import Foundation

@main struct CaptionShutdownSmoke {
    @MainActor static func main() async {
        // Deliberately ignores cancellation until its external input is finished.
        let (stream, input) = AsyncStream<Void>.makeStream()
        let stuck = Task { for await _ in stream {} }
        let start = ContinuousClock.now
        let timedOut = await CaptionTaskDeadline.wait(for: [stuck], timeout: .milliseconds(40))
        precondition(!timedOut && start.duration(to: .now) < .seconds(1))
        input.finish()
        await stuck.value // Late completion must not resume the continuation twice.

        let fast = Task {}
        let completed = await CaptionTaskDeadline.wait(for: [fast], timeout: .seconds(1))
        precondition(completed)
        let empty = await CaptionTaskDeadline.wait(for: [], timeout: .seconds(1))
        precondition(empty)

        var preview = CaptionPreview()
        preview.update("我做完了", now: 10)
        precondition(preview.visible(at: 11) == "我做完了")
        preview.update("我做完了", now: 17) // Repeated hallucinations do not reset age.
        precondition(preview.visible(at: 18) == nil)
        preview.update("正在讨论进度", now: 20)
        precondition(preview.visible(at: 21) == "正在讨论进度")
        preview.update("", now: 22)
        precondition(preview.visible(at: 22) == nil)
        print("PASS: unresponsive recognition cannot block shutdown, late completion is safe, stale/repeated previews expire")
    }
}
