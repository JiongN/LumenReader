import Foundation
import Testing
@testable import LumenKit

/// 微软翻译的凭证解析。
///
/// 只测**解析**这一段，不测联网：联网结果取决于必应当时的页面结构，
/// 把「页面改版」和「解析写错」两种失败混在一起，定位不到底是谁坏了。
/// 联网那一段另有一次性的实测记录（见 docs/VERIFY.md）。
@Suite("微软翻译凭证解析")
struct MicrosoftTranslatorTests {

    /// 从真实页面里截出来的一段（只留参数所在的上下文）。
    private static let page = """
    _G={Region:"CN",Lang:"zh-CN",IG:"351E58FA2F284705A4BBB40127F26B4F",EventID:"6aaeb7"};
    var params_AbusePreventionHelper = [1789835014974,"M3pf81DHJvl_vlP5HnG7vQmf9ZuVuUC1",3600000];
    var params_RichTranslateHelper = [true,null,false,"必应在线翻译"];
    <span id="id_d" _iid="translator.5021"></span>
    """

    @Test func parsesCredentialsFromRealPageShape() {
        let credentials = BingTranslateCredentialsParser.parse(html: Self.page)
        #expect(credentials != nil, "页面里有完整的四件套，不该解析失败")
        #expect(credentials?.key == "1789835014974")
        #expect(credentials?.token == "M3pf81DHJvl_vlP5HnG7vQmf9ZuVuUC1")
        #expect(credentials?.ig == "351E58FA2F284705A4BBB40127F26B4F")
        #expect(credentials?.iid == "translator.5021")
    }

    @Test func fallsBackToDefaultIIDWhenPageOmitsIt() {
        let withoutIID = Self.page.replacingOccurrences(of: "_iid=\"translator.5021\"", with: "")
        let credentials = BingTranslateCredentialsParser.parse(html: withoutIID)
        #expect(credentials != nil)
        #expect(credentials?.iid == "translator.5021", "页面没给 IID 时退回翻译页的固定值，而不是整份作废")
    }

    /// 反例：页面结构一变（参数不见了）必须返回 nil，让上层报「取不到凭证」。
    /// 静默返回一个空凭证，会让请求发出去再拿到 401，错误就指不到真正的源头。
    @Test func returnsNilWhenPageHasNoCredentials() {
        #expect(BingTranslateCredentialsParser.parse(html: "<html><body>登录 / 验证码</body></html>") == nil)
        #expect(BingTranslateCredentialsParser.parse(html: "") == nil)
        #expect(BingTranslateCredentialsParser.parse(html: "var params_AbusePreventionHelper = [];") == nil)
    }

    /// 时间戳那一项必须是纯数字——它是请求里的 `key`，带引号或空串都会被接口拒。
    @Test func rejectsNonNumericKey() {
        let broken = Self.page.replacingOccurrences(
            of: "params_AbusePreventionHelper = [1789835014974,",
            with: "params_AbusePreventionHelper = [\"1789835014974\","
        )
        #expect(BingTranslateCredentialsParser.parse(html: broken) == nil)
    }
}
