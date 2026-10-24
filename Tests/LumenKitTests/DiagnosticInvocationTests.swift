import Testing
@testable import LumenKit

@Suite("诊断与真实数据隔离")
struct DiagnosticInvocationTests {
    @Test func watchAndStandaloneOverridesAreDiagnostics() {
        for flag in ["--jank-watch", "--jump-to", "--window-size", "--panel-width", "--reading-theme", "--mock-ai", "--capture", "--startup-report"] {
            #expect(AppPaths.isDiagnosticInvocation(["Lumen", flag, "1"]))
        }
    }

    @Test func normalOpenAndReportNamedFileAreNotDiagnostics() {
        #expect(!AppPaths.isDiagnosticInvocation(["Lumen", "--open", "/tmp/document-report"]))
        #expect(!AppPaths.isDiagnosticInvocation(["Lumen", "--open", "/tmp/a.pdf"]))
        #expect(!AppPaths.isTestInvocation(["Lumen", "--open", "/tmp/PackageTests.pdf"]))
    }

    @Test func swiftTestingExecutableWithoutXCTestSuffixIsIsolated() {
        #expect(AppPaths.isTestInvocation(["/tmp/LumenReaderPackageTests"]))
        #expect(AppPaths.isDiagnosticInvocation(["/tmp/LumenReaderPackageTests"]))
        #expect(AppPaths.supportRoot != AppPaths.realSupportRoot)
    }

    @Test func publishedCapacityDoesNotOverrideExplicitBudgetOrUnknownEndpoints() {
        var config = AIProviderConfig(name: "ECNU", baseURL: "https://chat.ecnu.edu.cn/open/api/v1/", models: ["ecnu-max"], selectedModel: "ecnu-max")
        #expect(config.publishedContextWindow == 524_288)
        #expect(config.contextWindow == 32_768)
        #expect(ContextBudget.inputLimit(config) == 27_444)
        config.selectedModel = "ecnu-plus"
        #expect(config.publishedContextWindow == 262_144)
        config.contextWindow = 524_288
        #expect(ContextBudget.inputLimit(config) == 233_882)
        config.baseURL = "https://example.com/v1"
        #expect(config.publishedContextWindow == nil)
    }
}
