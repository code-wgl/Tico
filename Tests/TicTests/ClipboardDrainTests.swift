import Foundation
import Testing
@testable import Tic

@Suite("Clipboard write draining")
@MainActor
struct ClipboardDrainTests {
    @Test("waits until the in-flight write completes")
    func waitsForPendingWrite() async {
        var pending = true
        let finishing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            pending = false
        }
        let drained = await AppModel.waitForClipboardWrites(attempts: 50, interval: .milliseconds(5)) { pending }
        await finishing.value
        #expect(drained)
        #expect(!pending)
    }

    @Test("reports timeout rather than treating an unfinished write as saved")
    func timesOut() async {
        let drained = await AppModel.waitForClipboardWrites(attempts: 2, interval: .milliseconds(1)) { true }
        #expect(!drained)
    }
}
