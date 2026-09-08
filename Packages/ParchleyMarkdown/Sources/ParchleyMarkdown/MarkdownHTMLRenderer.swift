import Foundation
import Markdown

/// Converts Markdown to a static HTML fragment. Raw HTML is treated as text.
public enum MarkdownHTMLRenderer: Sendable {
    public static func render(_ source: String) -> String {
        let document = Document(parsing: source)
        return Renderer().render(document)
    }
}

private struct Renderer {
    func render(_ markup: Markup) -> String {
        if let text = markup as? Markdown.Text { return escape(text.string) }
        if let code = markup as? InlineCode { return "<code>\(escape(code.code))</code>" }
        if let paragraph = markup as? Paragraph { return "<p>\(children(paragraph))</p>" }
        if let heading = markup as? Heading { return "<h\(heading.level)>\(children(heading))</h\(heading.level)>" }
        if let emphasis = markup as? Emphasis { return "<em>\(children(emphasis))</em>" }
        if let strong = markup as? Strong { return "<strong>\(children(strong))</strong>" }
        if let link = markup as? Link { return linkHTML(link) }
        if let image = markup as? Image { return "<span>[Image: \(escape(children(image)))]</span>" }
        if let html = markup as? HTMLBlock { return escape(html.rawHTML) }
        if let html = markup as? InlineHTML { return escape(html.rawHTML) }
        if let code = markup as? CodeBlock { return "<pre><code>\(escape(code.code))</code></pre>" }
        if markup is SoftBreak { return "\n" }
        if markup is LineBreak { return "<br>\n" }
        if markup is ThematicBreak { return "<hr>" }
        if let quote = markup as? BlockQuote { return "<blockquote>\(children(quote))</blockquote>" }
        if let list = markup as? UnorderedList { return listHTML(list, ordered: false) }
        if let list = markup as? OrderedList {
            let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
            return "<ol\(start)>\(children(list))</ol>"
        }
        if markup is ListItem { return "<li>\(children(markup))</li>" }
        if let table = markup as? Table { return tableHTML(table) }
        return children(markup)
    }

    private func children(_ markup: Markup) -> String { markup.children.map(render).joined() }

    private func linkHTML(_ link: Link) -> String {
        guard let destination = link.destination,
              Self.isSafeExternalURL(destination) else {
            return children(link)
        }
        return "<a href=\"\(escapeAttribute(destination))\">\(children(link))</a>"
    }

    private static func isSafeExternalURL(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil || !components.fragment!.contains("\n") else {
            return false
        }
        return true
    }

    private func listHTML(_ list: Markup, ordered: Bool) -> String {
        let tag = ordered ? "ol" : "ul"
        return "<\(tag)>\(children(list))</\(tag)>"
    }

    private func tableHTML(_ table: Table) -> String {
        let head = table.head
        let header = "<thead><tr>\(head.children.map { "<th>\(children($0))</th>" }.joined())</tr></thead>"
        let rows = table.body.rows
        let body = rows.map { "<tr>\($0.children.map { "<td>\(children($0))</td>" }.joined())</tr>" }.joined()
        return "<table>\(header)<tbody>\(body)</tbody></table>"
    }

    private func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;") }
    private func escapeAttribute(_ value: String) -> String {
        escape(value).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
    }
}
