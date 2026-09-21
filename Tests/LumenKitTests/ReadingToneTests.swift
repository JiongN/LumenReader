import Testing
@testable import LumenKit

@Suite("阅读色调合成")
struct ReadingToneTests {
    @Test func endpointsAndMidtones() {
        let pairs: [(Double, Double)] = [(41,245),(57,243),(46,232),(219,37),(213,32)]
        for (ink, paper) in pairs {
            let channel = ReadingToneChannel(ink: ink/255, paper: paper/255)
            for input in [0.0,0.1,0.5,0.9,1.0] {
                let expected = ink/255 + (paper-ink)/255 * input
                #expect(abs(channel.map(input)-expected) < 0.000001)
            }
        }
    }
    @Test func degenerateAndInvalidChannels() {
        #expect(ReadingToneChannel(ink: 1, paper: 1).map(0.5) == 1)
        #expect(ReadingToneChannel(ink: 0, paper: 0).map(0.5) == 0)
        #expect(ReadingToneChannel(ink: .nan, paper: .infinity).map(0.5) == 0.5)
    }
}
