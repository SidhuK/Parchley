import Testing
@testable import ParchleyMarkdown

struct MarkdownHTMLRendererTests {
    @Test func rendersHeadingsListsAndTables() {
        let html = MarkdownHTMLRenderer.render("# Title\n\n- one\n- two\n\n| A | B |\n| --- | --- |\n| x | y |")
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<ul>"))
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>A</th>"))
    }

    @Test func escapesRawHTMLAndRejectsUnsafeLinks() {
        let html = MarkdownHTMLRenderer.render("<script>alert(1)</script>\n\n[bad](javascript:alert(1)) [file](file:///tmp/x) [ok](https://example.com)")
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!html.contains("javascript:"))
        #expect(!html.contains("file://"))
        #expect(html.contains("href=\"https://example.com\""))
    }

    @Test func neverEmitsImageSourcesOrInlineHTML() {
        let html = MarkdownHTMLRenderer.render("![pixel](https://tracker.invalid/pixel.gif) and <b>raw</b>")
        #expect(!html.contains("<img"))
        #expect(!html.contains("tracker.invalid"))
        #expect(html.contains("&lt;b&gt;raw&lt;/b&gt;"))
    }
}
