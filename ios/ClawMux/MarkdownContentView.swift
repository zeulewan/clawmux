import SwiftUI

// MARK: - Scroll Top Detector (auto-load older messages)

struct ScrollTopDetector: ViewModifier {
    @Binding var isLoadingOlder: Bool
    var hasOlderMessages: Bool
    var sessionId: String?
    var load: (String, @escaping () -> Void) -> Void

    // Post-load cooldown: blocks re-triggering while the scroll view settles after a load.
    // scrollPosition(id:) resolution can fire onScrollGeometryChange with distanceFromTop < 200
    // during the transition, so isLoadingOlder alone isn't a sufficient guard.
    @State private var cooldownUntil: Date = .distantPast

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            // Use CGFloat so action fires on every scroll event — avoids Bool toggle dead zone
            // where nearTop stays true after a load and action never re-fires.
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                // Distance from top in bottom-anchored coords (defaultScrollAnchor(.bottom)):
                //   contentOffset.y = 0 at bottom, negative when scrolled up
                //   → distanceFromTop = y + contentSize - containerSize
                //   → 0 when at top, (contentSize - containerSize) when at bottom
                geo.contentOffset.y + geo.contentSize.height - geo.containerSize.height
            } action: { _, distanceFromTop in
                guard distanceFromTop < 200,
                      !isLoadingOlder,
                      Date() >= cooldownUntil,
                      hasOlderMessages,
                      let sid = sessionId else { return }
                isLoadingOlder = true
                load(sid) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isLoadingOlder = false
                        // Hold off re-triggering for 1s after load completes — gives the scroll
                        // view time to settle at the restored anchor position.
                        cooldownUntil = Date().addingTimeInterval(1.0)
                    }
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Scroll Bottom Detector

struct ScrollBottomDetector: ViewModifier {
    @Binding var isAtBottom: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                // Empty or under-filled content is always "at bottom"
                if geo.contentSize.height <= geo.containerSize.height { return true }
                // Bottom-anchored coords (defaultScrollAnchor(.bottom)):
                // y=0 at bottom, negative = scrolled up
                return -geo.contentOffset.y < 120
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
        } else {
            content
        }
    }
}

// MARK: - Chat Scroll Lock

/// Permanently prevents horizontal drift in the chat ScrollView.
/// Applied as .background(ChatScrollLock()) — the UIView sits inside the scroll view's
/// content layer, giving us a stable anchor to walk up and find the UIScrollView.
///
/// Strategy:
/// - Retries the superview walk every 0.1s until the scroll view is found (handles
///   the case where the view isn't in the hierarchy yet at makeUIView time).
/// - Stores the original SwiftUI delegate and forwards all calls to it via
///   forwardingTarget(for:) so SwiftUI's internal scroll machinery keeps working.
/// - scrollViewDidScroll hard-clamps contentOffset.x to 0 on every scroll event.
struct ChatScrollLock: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var originalDelegate: UIScrollViewDelegate?
        private var retryCount = 0
        private let maxRetries = 30  // 3 seconds max

        func attach(to view: UIView) {
            retryCount = 0
            findScrollView(in: view)
        }

        private func findScrollView(in view: UIView) {
            var superview = view.superview
            while let sv = superview {
                if let found = sv as? UIScrollView {
                    configure(found)
                    return
                }
                superview = sv.superview
            }
            // Not in hierarchy yet — retry after one frame, with cap
            retryCount += 1
            guard retryCount < maxRetries else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
                guard let self, let view else { return }
                self.findScrollView(in: view)
            }
        }

        private func configure(_ sv: UIScrollView) {
            scrollView = sv
            originalDelegate = sv.delegate
            sv.isDirectionalLockEnabled = true
            sv.alwaysBounceHorizontal = false
            sv.delegate = self
        }

        // Clamp horizontal offset to zero on every scroll event
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.contentOffset.x != 0 {
                scrollView.setContentOffset(
                    CGPoint(x: 0, y: scrollView.contentOffset.y),
                    animated: false)
            }
            originalDelegate?.scrollViewDidScroll?(scrollView)
        }

        // Forward all other UIScrollViewDelegate calls to SwiftUI's internal delegate
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if originalDelegate?.responds(to: aSelector) == true { return originalDelegate }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

// MARK: - Markdown Content View

struct MarkdownContentView: View {
    let text: String
    let foreground: Color
    var fontSize: CGFloat = 15
    var baseURL: String = ""

    /// Parses inline markdown (bold, italic, `code`) using AttributedString so
    /// backtick code spans render as monospaced — LocalizedStringKey does not handle `code`.
    private static let attrCache = NSCache<NSString, NSAttributedString>()

    private static func inlineMarkdown(_ str: String) -> AttributedString {
        if let cached = attrCache.object(forKey: str as NSString) {
            return (try? AttributedString(cached, including: \.foundation)) ?? AttributedString(str)
        }
        let result = (try? AttributedString(markdown: str,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(str)
        if let ns = try? NSAttributedString(result, including: \.foundation) {
            attrCache.setObject(ns, forKey: str as NSString)
        }
        return result
    }

    /// Strips `$` / `$$` delimiters from a math expression before passing to KaTeX.
    private static func stripMathDelimiters(_ expr: String, isBlock: Bool) -> String {
        var s = expr
        let delim = isBlock ? "$$" : "$"
        if s.hasPrefix(delim) { s = String(s.dropFirst(delim.count)) }
        if s.hasSuffix(delim) { s = String(s.dropLast(delim.count)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum Block {
        case text(String)
        case header(Int, String)
        case bullet(String)
        case numbered(String, String)
        case code(String, String)   // (language, content)
        case blockquote(String)
        case rule
        case spacing
        case math(String, Bool)     // (expression incl. delimiters, isBlock/display)
        case image(String, String)  // (alt text, url path)
        case table(headers: [String], rows: [[String]])
    }

    private func parse(_ raw: String) -> [Block] {
        var result: [Block] = []
        var lines  = raw.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            // Block math fence: $$ ... $$ (may span lines)
            if trimmedLine.hasPrefix("$$") {
                // Check if opening and closing $$ are on the same line (e.g. "$$expr$$")
                let afterOpen = String(trimmedLine.dropFirst(2))
                if afterOpen.hasSuffix("$$") && afterOpen.count > 2 {
                    // Single-line block math: $$expr$$
                    let expr = "$$" + String(afterOpen.dropLast(2)) + "$$"
                    result.append(.math(expr, true))
                    i += 1; continue
                } else if afterOpen == "" || afterOpen.hasSuffix("$$") == false {
                    // Multi-line block math: collect until closing $$
                    var mathLines: [String] = []
                    if !afterOpen.isEmpty { mathLines.append(afterOpen) }
                    i += 1
                    while i < lines.count {
                        let ml = lines[i].trimmingCharacters(in: .whitespaces)
                        if ml == "$$" || ml.hasSuffix("$$") {
                            if ml != "$$" { mathLines.append(String(ml.hasSuffix("$$") ? String(ml.dropLast(2)) : ml)) }
                            i += 1; break
                        }
                        mathLines.append(lines[i]); i += 1
                    }
                    let expr = "$$" + mathLines.joined(separator: "\n") + "$$"
                    result.append(.math(expr, true))
                    continue
                }
            }
            // Inline math: line is purely $...$ with no other content
            if trimmedLine.hasPrefix("$") && trimmedLine.hasSuffix("$") && trimmedLine.count > 2
                && !trimmedLine.hasPrefix("$$") {
                let inner = String(trimmedLine.dropFirst().dropLast())
                if !inner.contains("$") {
                    result.append(.math("$" + inner + "$", false))
                    i += 1; continue
                }
            }
            // Markdown table: header row starts/ends with | and next line is separator
            if trimmedLine.hasPrefix("|") && trimmedLine.hasSuffix("|"),
               i + 1 < lines.count {
                let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
                let isSeparator = nextTrimmed.hasPrefix("|") && nextTrimmed.hasSuffix("|")
                    && nextTrimmed.replacingOccurrences(of: "|", with: "")
                        .replacingOccurrences(of: "-", with: "")
                        .replacingOccurrences(of: ":", with: "")
                        .trimmingCharacters(in: .whitespaces).isEmpty
                if isSeparator {
                    let parseRow: (String) -> [String] = { row in
                        row.split(separator: "|", omittingEmptySubsequences: false)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty || row.hasPrefix("|") }
                            .dropFirst(row.hasPrefix("|") ? 1 : 0)
                            .dropLast(row.hasSuffix("|") ? 1 : 0)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                    let headers = parseRow(trimmedLine)
                    i += 2 // skip header + separator
                    var rows: [[String]] = []
                    while i < lines.count {
                        let r = lines[i].trimmingCharacters(in: .whitespaces)
                        guard r.hasPrefix("|") && r.hasSuffix("|") else { break }
                        rows.append(parseRow(r))
                        i += 1
                    }
                    result.append(.table(headers: headers, rows: rows))
                    continue
                }
            }
            // Image: ![alt](url) on its own line
            if let m = trimmedLine.firstMatch(of: /^!\[([^\]]*)\]\(([^)]+)\)$/) {
                result.append(.image(String(m.output.1), String(m.output.2)))
                i += 1; continue
            }
            // Code fence
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                result.append(.code(lang, codeLines.joined(separator: "\n")))
                continue
            }
            if line.hasPrefix("### ") { result.append(.header(3, String(line.dropFirst(4)))); i += 1; continue }
            if line.hasPrefix("## ")  { result.append(.header(2, String(line.dropFirst(3)))); i += 1; continue }
            if line.hasPrefix("# ")   { result.append(.header(1, String(line.dropFirst(2)))); i += 1; continue }
            if line.hasPrefix("> ") { result.append(.blockquote(String(line.dropFirst(2)))); i += 1; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { result.append(.rule); i += 1; continue }
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ") {
                result.append(.bullet(String(stripped.dropFirst(2)))); i += 1; continue
            }
            if let m = stripped.firstMatch(of: /^(\d+)\. (.+)/) {
                result.append(.numbered(String(m.output.1), String(m.output.2))); i += 1; continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if case .spacing? = result.last {} else { result.append(.spacing) }
                i += 1; continue
            }
            // Merge consecutive plain text lines into one paragraph — single newline = space
            // (standard markdown: only double newline creates a paragraph break)
            if case .text(let prev) = result.last {
                result[result.count - 1] = .text(prev + " " + line)
            } else {
                result.append(.text(line))
            }
            i += 1
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .spacing:
            Color.clear.frame(height: 3)

        case .text(let str):
            Text(Self.inlineMarkdown(str))
                .font(.system(size: fontSize))
                .foregroundStyle(foreground)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case .header(let level, let str):
            let sz: CGFloat = level == 1 ? fontSize + 4 : level == 2 ? fontSize + 1 : fontSize - 1
            let wt: Font.Weight = level <= 2 ? .bold : .semibold
            Text(Self.inlineMarkdown(str))
                .font(.system(size: sz, weight: wt))
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let str):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color.cTextSec)
                    .frame(width: 10)
                Text(Self.inlineMarkdown(str))
                    .font(.system(size: fontSize))
                    .foregroundStyle(foreground)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .numbered(let num, let str):
            HStack(alignment: .top, spacing: 6) {
                Text("\(num).")
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color.cTextSec)
                    .frame(width: 22, alignment: .trailing)
                Text(Self.inlineMarkdown(str))
                    .font(.system(size: fontSize))
                    .foregroundStyle(foreground)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .blockquote(let str):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color.cTextTer.opacity(0.5)).frame(width: 3)
                Text(Self.inlineMarkdown(str))
                    .font(.system(size: fontSize))
                    .foregroundStyle(foreground.opacity(0.75))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)

        case .rule:
            Divider().background(Color.cBorder)

        case .code(let lang, let content):
            VStack(alignment: .leading, spacing: 0) {
                // Header: language label + copy button (mirrors web .code-copy-btn)
                HStack {
                    Text(lang.isEmpty ? "code" : lang)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cTextTer)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = content
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.cTextTer)
                            .padding(4)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.cText)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.canvas2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.cBorder, lineWidth: 0.5))

        case .math(let expr, let isBlock):
            MathBlockView(expression: Self.stripMathDelimiters(expr, isBlock: isBlock),
                          isBlock: isBlock)

        case .table(let headers, let rows):
            // Equal-width columns: each cell gets frame(maxWidth: .infinity) so HStack distributes
            // space evenly. No horizontal scroll, no PreferenceKey — zero layout pollution.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(headers.indices, id: \.self) { i in
                        Text(headers[i])
                            .font(.system(size: fontSize - 1, weight: .semibold))
                            .foregroundStyle(foreground)
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if i < headers.count - 1 { Color.cBorder.frame(width: 0.5) }
                    }
                }
                .background(Color.canvas2)
                Color.cBorder.frame(height: 0.5)
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(rows[r].indices, id: \.self) { c in
                            Text(rows[r][c])
                                .font(.system(size: fontSize - 1))
                                .foregroundStyle(foreground)
                                .lineLimit(1).truncationMode(.tail)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if c < rows[r].count - 1 { Color.cBorder.frame(width: 0.5) }
                        }
                    }
                    if r < rows.count - 1 { Color.cBorder.frame(height: 0.5) }
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.cBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .image(let alt, let path):
            ImageBlockView(alt: alt, path: path, baseURL: baseURL, fontSize: fontSize)
        }
    }
}

extension MarkdownContentView: Equatable {
    nonisolated static func == (lhs: MarkdownContentView, rhs: MarkdownContentView) -> Bool {
        lhs.text == rhs.text && lhs.foreground == rhs.foreground &&
        lhs.fontSize == rhs.fontSize && lhs.baseURL == rhs.baseURL
    }
}

// MARK: - Lazy Image Block
// Shows a load button instead of auto-fetching — user must tap to load.
private struct ImageBlockView: View {
    let alt: String
    let path: String
    let baseURL: String
    let fontSize: CGFloat
    @State private var loaded = false

    private var resolvedURL: URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: base + path)
    }

    var body: some View {
        if loaded, let url = resolvedURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit().frame(maxWidth: .infinity).cornerRadius(8)
                case .failure:
                    HStack(spacing: 6) {
                        Image(systemName: "photo").foregroundStyle(Color.cTextTer)
                        Text(alt.isEmpty ? path : alt)
                            .font(.system(size: fontSize - 1)).foregroundStyle(Color.cTextTer)
                    }
                case .empty:
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading…").font(.system(size: fontSize - 1)).foregroundStyle(Color.cTextTer)
                    }
                @unknown default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            Button { loaded = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(Color.cTextSec)
                    Text(alt.isEmpty ? "Load image" : alt)
                        .font(.system(size: fontSize - 1)).foregroundStyle(Color.cTextSec)
                    Spacer()
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13)).foregroundStyle(Color.cAccent)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.cCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.cBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }
}
