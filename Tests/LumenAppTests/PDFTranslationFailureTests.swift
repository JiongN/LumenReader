import Foundation
import Testing
@testable import LumenApp

@Suite("PDF 翻译服务故障")
@MainActor
struct PDFTranslationFailureTests {
    @Test func connectionFailureStopsDocumentQueue() {
        let tls = URLError(.secureConnectionFailed)
        #expect(PDFTranslationController.isServiceWideFailure(tls))
        #expect(PDFTranslationController.describe(tls).contains("安全连接"))
        #expect(PDFTranslationController.isServiceWideFailure(URLError(.notConnectedToInternet)))
        #expect(!PDFTranslationController.isServiceWideFailure(URLError(.cancelled)))
    }
}
