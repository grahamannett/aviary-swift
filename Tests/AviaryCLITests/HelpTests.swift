import Testing
import AviaryCLI

@Suite struct HelpTests {
    @Test func shorthand() {
        let out = AviaryRoot.rewrittenArguments(["2098225368230732160", "--json"])
        #expect(out.first == "read")
        let url = AviaryRoot.rewrittenArguments(["https://x.com/RichardMCNgo/status/2098225368230732160"])
        #expect(url.first == "read")
        let keep = AviaryRoot.rewrittenArguments(["thread", "1"])
        #expect(keep.first == "thread")
    }
}
