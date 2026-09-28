import XCTest
import AviaryCLI

final class HelpTests: XCTestCase {
    func testShorthand() {
        let out = AviaryRoot.rewrittenArguments(["2098225368230732160", "--json"])
        XCTAssertTrue(out.first == "read")
        let url = AviaryRoot.rewrittenArguments(["https://x.com/RichardMCNgo/status/2098225368230732160"])
        XCTAssertTrue(url.first == "read")
        let keep = AviaryRoot.rewrittenArguments(["thread", "1"])
        XCTAssertTrue(keep.first == "thread")
    }
}
