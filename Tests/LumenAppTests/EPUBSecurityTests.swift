import Foundation
import Testing
import WebKit
import JavaScriptCore
import Network
import Synchronization
@testable import LumenApp

@Suite("EPUB 内容隔离", .serialized)
@MainActor
struct EPUBSecurityTests {
    @Test func offlineRulesBlockRemoteImagesButNotLocalContent() async throws {
        let connections = Mutex(0)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connections.withLock { $0 += 1 }
            connection.start(queue: .global())
            connection.cancel()
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let port = try #require(listener.port)
        try #require(port.rawValue > 0)
        // HTTPS reaches the socket even under the test runner's strict ATS defaults.
        let remote = "https://127.0.0.1:\(port.rawValue)/tracking.png"
        let probeConfiguration = URLSessionConfiguration.ephemeral
        probeConfiguration.connectionProxyDictionary = [:]
        probeConfiguration.timeoutIntervalForResource = 2
        let probe = URLSession(configuration: probeConfiguration)
        _ = try? await probe.data(from: URL(string: remote)!)
        probe.invalidateAndCancel()
        try #require(connections.withLock { $0 } > 0)
        let compiled = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "lumen-test-offline-images", encodedContentRuleList: EPUBController.resourceRules)
        let rules = try #require(compiled)
        for blocked in [false, true] {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.websiteDataStore.proxyConfigurations = []
            if blocked { configuration.userContentController.add(rules) }
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            let before = connections.withLock { $0 }
            view.loadHTMLString("<p id='local'>Local content</p><img src='\(remote)' onerror='window.imageDone=true'>", baseURL: nil)
            var finished = false
            for _ in 0..<150 {
                try await Task.sleep(for: .milliseconds(20))
                if (try? await view.evaluateJavaScript("window.imageDone === true")) as? Bool == true {
                    finished = true; break
                }
            }
            #expect(finished)
            #expect(try await view.evaluateJavaScript("document.getElementById('local').textContent") as? String == "Local content")
            if blocked { #expect(connections.withLock { $0 } == before) }
            else { #expect(connections.withLock { $0 } > before) }
            view.stopLoading()
        }
        try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: rules.identifier)
    }

    @Test func bookTextIsDataNotJavaScript() throws {
        let context = try #require(JSContext())
        for text in ["a\r\nb", "a\u{2028}b\u{2029}c", "'\"\\\t\0", "');globalThis.injected=true;//", "中文 👩‍💻"] {
            let result = context.evaluateScript(EPUBController.jsString(text))
            #expect(context.exception == nil)
            #expect(result?.toString() == text)
        }
        #expect(context.objectForKeyedSubscript("injected")?.isUndefined == true)
    }

    @Test func webKitAcceptsOfflineResourceRules() async throws {
        let rules: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "lumen-test-offline",
                encodedContentRuleList: EPUBController.resourceRules) { rules, error in
                if let rules { continuation.resume(returning: rules) }
                else { continuation.resume(throwing: error ?? NSError(domain: "test", code: 1)) }
            }
        }
        #expect(rules.identifier == "lumen-test-offline")
        try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: rules.identifier)
    }
}
