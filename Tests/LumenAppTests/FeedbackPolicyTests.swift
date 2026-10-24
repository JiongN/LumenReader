import Testing
@testable import LumenApp

@Suite("安静完成与异常提示", .serialized)
@MainActor
struct FeedbackPolicyTests {
    @Test func successDoesNotCreateOrReplaceErrorToast() {
        let state = AppState()
        state.showToast("批注已保存")
        #expect(state.toast == nil)
        state.showToast("保存失败", isError: true)
        let errorID = state.toast?.id
        state.showToast("已复制")
        #expect(state.toast?.id == errorID)
        #expect(state.toast?.isError == true)
        state.dismissToast()
        state.showToast("材料缺页", requiresAttention: true)
        #expect(state.toast?.message == "材料缺页")
        state.dismissToast()
    }
}
