import Foundation
import LumenKit

@MainActor enum SessionLifecycleAudit {
    static func run(services: AppServices) {
        let workspace = AppState(services: services)
        let session = ReaderSession(document: OpenDocument(url: URL(fileURLWithPath: "/tmp/lumen-lifecycle-fixture.pdf"), kind: .pdf))
        var cancelled = 0, closed = 0
        session.busyCancel = { cancelled += 1 }
        session.bridge.closeReader = { closed += 1 }
        session.bridge.goToNextUnit = {}
        workspace.add(session)
        workspace.withdraw(session)
        let movedWithoutStopping = cancelled == 0 && closed == 0 && session.bridge.goToNextUnit != nil
        workspace.add(session)
        workspace.close(session)
        let closedExactlyOnce = cancelled == 1 && closed == 1 && session.bridge.goToNextUnit == nil
        session.close()
        let idempotent = cancelled == 1 && closed == 1
        NSLog("[Lumen][lifecycle] movePreserves=%@ closeCancels=%@ idempotent=%@ pass=%@",
              String(movedWithoutStopping), String(closedExactlyOnce), String(idempotent),
              String(movedWithoutStopping && closedExactlyOnce && idempotent))
    }
}
