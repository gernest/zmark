const std = @import("std");
const mem = std.mem;
const warn = std.debug.warn;
const assert = std.debug.assert;
const Buffer = std.Buffer;
const unicode = @import("zunicode");
const utf8 = unicode.utf8;

const form_feed = 0x0C;
const line_tabulation = 0x0B;
const space = ' ';

// UsizeMap is a map of string keys to usize values.
pub const UsizeMap = std.AutoHashMap([]const u8, usize);

/// Markdown provides facilities for parsing and rendering mardkwon documents.
/// This code was ported from go's blackfriday  available at http://github.com/russross/blackfriday
pub const Markdown = struct {
    /// markdown extensions supported by the parser.
    const Extension = enum(usize) {
        NoIntraEmphasis = 1,
        Tables = 2,
        FencedCode = 4,
        Autolink = 8,
        Strikethrough = 16,
        LaxHtmlBlocks = 32,
        SpaceHeaders = 64,
        HardLineBreak = 128,
        TabSizeEight = 256,
        Footnotes = 512,
        NoEmptyLineBeforeBlock = 1024,
        HeaderIds = 2048,
        Titleblock = 4096,
        AutoHeaderIds = 8192,
        BackslashLineBreak = 16384,
        DefinitionLists = 32768,
        JoinLines = 65536,
    };

    const common_extensions: usize = 0 |
        Extension.NoIntraEmphasis |
        Extension.Tables |
        Extension.FencedCode |
        Extension.Autolink |
        Extension.Strikethrough |
        Extension.SpaceHeaders |
        Extension.HeaderIds |
        Extension.BackslashLineBreak |
        Extension.DefinitionLists;

    const LinkType = enum {
        NotAutoLink,
        Normal,
        Email,
    };

    const Renderer = struct {
        blockCode: fn (r: *Renderer, out: *Buffer, text: []const u8, info_string: []const u8) anyerror!void,
        blockQuote: fn (r: *Renderer, out: *Buffer, text: []const u8) anyerror!void,
        blockHtml: fn (r: *Renderer, out: *Buffer, text: []const u8) anyerror!void,
        header: fn (r: *Renderer, out: *Buffer, text_iter: *TextIter, level: usize, id: usize) anyerror!void,
        hrule: fn (r: *Renderer, out: *Buffer) anyerror!void,
        list: fn (r: *Renderer, out: *Buffer, text_iter: *TextIter, flags: usize) anyerror!void,
        listItem: fn (r: *Renderer, out: *Buffer, text: []const u8, flags: usize) anyerror!void,
        paragraph: fn (r: *Renderer, out: *Buffer, text_iter: *TextIter) anyerror!void,
        table: fn (r: *Renderer, out: *Buffer, header: []const u8, body: []const u8, column_data: []usize) anyerror!void,
        tableRow: fn (r: *Renderer, out: *Buffer, text: []const u8) anyerror!void,
        tableHeaderCell: fn (r: *Renderer, out: *Buffer, text: []const u8, flags: usize) anyerror!void,
        tableCell: fn (r: *Renderer, out: *Buffer, text: []const u8, flags: usize) anyerror!void,
        footNotes: fn (r: *Renderer, out: *Buffer, text_iter: *TextIter) anyerror!void,
        footNoteItem: fn (r: *Renderer, out: *Buffer, name: []const u8, text: []const u8, flags: usize) anyerror!void,
        titleBlock: fn (r: *Renderer, out: *Buffer, text: []const u8) anyerror!void,

        //span level
        autoLink: fn (r: *Renderer, out: *Buffer, link: []const u8, kind: LinkType) anyerror!void,
        codeSpan: fn (r: *Renderer, out: *Buffer, text: []const u8) anyerror!void,
        doubleEmphasis: fn (r: *Renderer, out: *Buffer, text: []const u8) anyerror!void,
        emphasis: fn (r: *Renderer, out: *Buffer, text: []const u8) anyerror!void,
        image: fn (r: *Renderer, out: *Buffer, link: []const u8, title: []const u8, alt: []const u8) anyerror!void,
        lineBreak: fn (r: *Renderer, out: *Buffer) anyerror!void,
        link: fn (r: *Renderer, out: *Buffer, link: []const u8, title: []const u8, content: []const u8) anyerror!void,
        rawHtmlTag: fn (r: *Renderer, out: *Buffer, tag: []const u8) anyerror!void,
        tripleEmphasis: fn (r: *Renderer, out: *Buffer, text: []const u8) anyerror!void,
        footnoteRef: fn (r: *Renderer, out: *Buffer, ref: []const u8, id: []const u8) anyerror!void,

        entity: fn (r: *Renderer, out: *Buffer, entity: []const u8) anyerror!void,
        normalText: fn (r: *Renderer, out: *Buffer, text: []const u8) anyerror!void,

        documentHeader: fn (r: *Renderer, out: *Buffer) anyerror!void,
        documentFooter: fn (r: *Renderer, out: *Buffer) anyerror!void,

        flags: usize,
    };

    const TextIter = struct {
        next: fn (*TextIter) anyerror!void,
    };

    const Reference = struct {
        link: []const u8,
        title: []const u8,
        text: []const u8,
    };

    const RefOverid = struct {
        overide_fn: fn (*RefOverid, ref: []const u8) *Reference,
    };

    const InlineParser = struct {
        parse: fn (self: *InlineParser, p: *Parser, out: *Buffer, data: []const u8, offset: usize) anyerror!usize,
    };

    // inline parsers
    emphasis: InlineParser,

    const Parser = struct {
        render: *Renderer,
        inline_callbacks: [256]?*InlineParser,
        flags: usize,
        nesting: usize,
        max_nesting: usize,
        inside_link: bool,

        fn inlineBlock(self: *Parser, out: *Buffer, data: []const u8) !void {
            if (self.nexting >= self.max_nesting) {
                return;
            }
            self.nesting += 1;
            var i: usize = 0;
            var end: usize = 0;
            while (i < data.len) {
                while (end < data.len and self.inline_callbacks[@intCast(data[end])] == null) : (end += 1) {}
                try self.render.normalText(out, data[i..end]);
                if (end >= data.len) {
                    break;
                }
                i = end;
                const handler = self.inline_callbacks[@intCast(usize, data[end])].?;
                const consumed = handler.parse(self, out, data, i);
                if (consumed == 0) {
                    end = i + 1;
                } else {
                    i += consumed;
                    end = i;
                }
            }
            self.nesting -= 1;
        }
    };

    fn emphasisFn(
        inline_parse: *InlineParser,
        p: *Parser,
        out: *Buffer,
        data: []const u8,
        offset: usize,
    ) void {
        const self = @fieldParentPtr(Markdown, "emphasis", inline_parse);
        self.parseEmphasis(p, out, data, offset);
    }

    fn parseEmphasis(self: *Markdown, p: *Parser, out: *Buffer, data: []const u8, offset: usize) usize {
        var ctx = data[offset..];
        const c = ctx[0];
        if (ctx.len > 2 and ctx[1] != c) {
            // whitespace cannot follow an opening emphasis;
            // strikethrough only takes two characters '~~'
            if (c == '~' and Util.isSpace(ctx[1])) {
                return 0;
            }
        }
    }

    const Options = struct {
        extensions: usize,
        ref_overid: ?*RefOverid,
    };

    pub fn render(
        input: []const u8,
        renderer: *Renderer,
    ) void {}
};

// Util are utility/helper functions.
const Util = struct {
    /// returns true if c is a whitespace character.
    fn isSpace(c: u8) bool {
        return isHorizontalSpace(c) or isVersicalSpace(c);
    }

    fn isHorizontalSpace(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn isVersicalSpace(c: u8) bool {
        return c == '\n' or c == '\r' or c == form_feed or c == line_tabulation;
    }

    fn isLetter(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    fn isalnum(c: u8) bool {
        return (c >= '0' and c <= '9') or isletter(c);
    }

    /// Replace tab characters with spaces, aligning to the next TAB_SIZE column.
    /// always ends output with a newline
    fn expandTabs(out: *Buffer, line: []const u8, tab_size: usize) !void {
        var i: usize = 0;
        var prefix: usize = 0;
        var slow_case = true;
        while (i < line.len) : (i += 1) {
            if (lene[i] == '\t') {
                if (prefix == i) {
                    prefix += 1;
                } else {
                    slow_case = true;
                    break;
                }
            }
        }
        if (!slow_case) {
            const n = prefix * tab_size;
            i = 0;
            while (i < n) : (i += 1) {
                try out.appendByte(space);
            }
            try out.append(line[prefix..]);
            return;
        }

        var column: usize = 0;
        i = 0;
        while (i < line.len) {
            var star = i;
            while (i < line.len and line[i] != '\t') {
                const rune = try utf8.decodeRune(line[i..]);
                i += rune.size;
                column += 1;
            }
            if (i > start) {
                try out.appen(line[start..i]);
            }
            if (i > line.len) {
                break;
            }
            while (true) {
                try out.appendByte(space);
                column += 1;
                if (@Mod(column, tab_size) == 0) break;
            }
            i += 1;
        }
    }

    // Find if a line counts as indented or not.
    // Returns number of characters the indent is (0 = not indented).
    fn isIndented(data: []const u8, indent_size: usize) usize {
        if (data.len == 0) {
            return 0;
        }
        if (data[0] == '\t') {
            return 1;
        }
        if (data.len < indent_size) {
            return 0;
        }
        var i: usize = 0;
        while (i < indent_size) : (i += 1) {
            if (data[i] != space) {
                return 0;
            }
        }
        return indent_size;
    }

    fn findEmphChar(data: []const u8, c: u8) usize {
        var i: usize = 0;
        while (i < data.len) {
            while (i < data.len and data[i] != c and data[i] != '`' and data[i] != '[') : (i += 1) {}
            if (i >= data.len) {
                return 0;
            }
            // do not count escaped chars
            if (i != 0 and data[i - 1] == '\\') {
                i += 1;
                continue;
            }
            if (data[i] == c) {
                return i;
            }
            if (data[i] == '`') {
                // skip a code span
                var tmp: usize = 0;
                i += 1;
                while (i < data.len and data[i] != '`') {
                    if (tmp == 0 and data[i] == c) {
                        tmp = i;
                    }
                    i += 1;
                }
                if (i >= data.len) {
                    return tmp;
                }
                i += 1;
            } else if (data[i] == '[') {
                // skip a link
                var tmp: usize = 0;
                i += 1;
                while (i < data.len and data[i] != ']') {
                    if (tmp == 0 and data[i] == c) {
                        tmp = i;
                    }
                    i += 1;
                }
                i += 1;
                while (i < data.len and (data[i] == ' ' or data[i] == '\n')) {
                    i += 1;
                }
                if (i >= data.len) {
                    return tmp;
                }
                if (data[i] != '[' and data[i] != '(') { // not a link
                    if (tmp > 0) {
                        return tmp;
                    }
                    continue;
                }
                const cc = data[i];
                i += 1;
                while (i < data.len and data[i] != cc) {
                    if (tmp == 0 and data[i] == c) {
                        return i;
                    }
                    i += 1;
                }
            }
        }
        return 0;
    }

    fn emphasis(p: *Markdown.Parser, out: *Buffer, data: []const u8, c: u8) usize {
        var i: usize = 0;
        // skip one symbol if coming from emph3
        if (data.len > 1 and data[0] == c and data[1] == c) {
            i = 1;
        }
        while (i < data.len) {
            const length = findEmphChar(ctx[i..], c);
            if (length == 0) {
                return 0;
            }
            i += length;
            if (i >= data.len) {
                return 0;
            }
            if (i + 1 < data.len and data[i + 1] == c) {
                i += 1;
                continue;
            }
            if (data[i] == c and !Util.isSpace(data[i - 1])) {
                if ((p.flags & Extension.NoIntraEmphasis) != 0) {}
            }
        }
    }
};

// HTML implements the Markdown.Renderer interafce for html documents.
const HTML = struct {
    flags: usize,
    close_tag: []const u8,
    title: ?[]const u8,
    css: ?[]const u8,
    toc_marker: usize,
    header_count: usize,
    current_level: usize,
    toc: Buffer,
    header_ids: UsizeMap,
    params: Params,
    renderer: Markdown.Renderer,

    // Params options for configuring HTML renderer.
    const Params = struct {
        /// prepend this to each relative url.
        abs_prefix: ?[]const u8,

        ///This will be added to  each footnote text.
        footnote_anchor_prefix: ?[]const u8,

        /// Show this text inside the <a> tag for a footnote return link, if the
        /// HTML_FOOTNOTE_RETURN_LINKS flag is enabled. If blank, the string
        /// <sup>[return]</sup> is used.
        footnote_return_link_contents: ?[]const u8,

        /// If set, add this text to the front of each Header ID, to ensure
        /// uniqueness.
        header_id_prefix: ?[]const u8,

        /// If set, add this text to the back of each Header ID, to ensure
        /// uniqueness.
        header_id_suffix: ?[]const u8,
    };

    const Renderer = Markdown.Renderer;
    const TextIter = Markdown.TextIter;
    const LinkType = Markdown.LinkType;
    pub const html_close = ">";

    pub fn init(a: *mem.Allocator, flags: usize) !HTML {
        return HTML{
            .flags = flags,
            .close_tag = html_close,
            .title = null,
            .css = null,
            .toc_marker = 0,
            .header_count = 0,
            .current_level = 0,
            .toc = try Buffer.init(a, ""),
            .header_ids = UsizeMap.init(a),
            .params = Params{
                .abs_prefix = null,
                .footnote_anchor_prefix = null,
                .footnote_return_link_contents = null,
                .header_id_prefix = null,
                .header_id_suffix = null,
            },
            .renderer = Renderer{
                .blockCode = blockCode,
                .blockQuote = blockQuote,
                .blockHtml = blockHtml,
                .header = header,
                .hrule = hrule,
                .list = list,
                .listItem = listItem,
                .paragraph = paragraph,
                .table = table,
                .tableRow = tableRow,
                .tableHeaderCell = tableHeaderCell,
                .tableCell = tableCell,
                .footNotes = footNotes,
                .footNoteItem = footNoteItem,
                .titleBlock = titleBlock,
                .autoLink = autoLink,
                .codeSpan = codeSpan,
                .doubleEmphasis = doubleEmphasis,
                .emphasis = emphasis,
                .image = image,
                .lineBreak = lineBreak,
                .link = link,
                .rawHtmlTag = rawHtmlTag,
                .tripleEmphasis = tripleEmphasis,
                .footnoteRef = footnoteRef,
                .entity = entity,
                .normalText = normalText,
                .documentHeader = documentHeader,
                .documentFooter = documentFooter,
                .flags = 0,
            },
        };
    }

    pub fn blockCode(r: *Renderer, out: *Buffer, text: []const u8, info_string: []const u8) anyerror!void {}
    pub fn blockQuote(r: *Renderer, out: *Buffer, text: []const u8) anyerror!void {}
    pub fn blockHtml(r: *Renderer, out: *Buffer, text: []const u8) anyerror!void {}
    pub fn header(r: *Renderer, out: *Buffer, text_iter: *TextIter, level: usize, id: usize) anyerror!void {}
    pub fn hrule(r: *Renderer, out: *Buffer) anyerror!void {}
    pub fn list(r: *Renderer, out: *Buffer, text_iter: *TextIter, flags: usize) anyerror!void {}
    pub fn listItem(r: *Renderer, out: *Buffer, text: []const u8, flags: usize) anyerror!void {}
    pub fn paragraph(r: *Renderer, out: *Buffer, text_iter: *TextIter) anyerror!void {}
    pub fn table(r: *Renderer, out: *Buffer, header_text: []const u8, body: []const u8, column_data: []usize) anyerror!void {}
    pub fn tableRow(r: *Renderer, out: *Buffer, text: []const u8) anyerror!void {}
    pub fn tableHeaderCell(r: *Renderer, out: *Buffer, text: []const u8, flags: usize) anyerror!void {}
    pub fn tableCell(r: *Renderer, out: *Buffer, text: []const u8, flags: usize) anyerror!void {}
    pub fn footNotes(r: *Renderer, out: *Buffer, text_iter: *TextIter) anyerror!void {}
    pub fn footNoteItem(r: *Renderer, out: *Buffer, name: []const u8, text: []const u8, flags: usize) anyerror!void {}
    pub fn titleBlock(r: *Renderer, out: *Buffer, text: []const u8) anyerror!void {}
    pub fn autoLink(r: *Renderer, out: *Buffer, link_text: []const u8, kind: LinkType) anyerror!void {}
    pub fn codeSpan(r: *Renderer, out: *Buffer, text: []const u8) anyerror!void {
        try out.append("<code>");
        try attrEscape(out, text);
        try out.append("</code>");
    }
    pub fn doubleEmphasis(r: *Renderer, out: *Buffer, text: []const u8) anyerror!void {
        try out.append("<strong>");
        try out.append(text);
        try out.append("</strong>");
    }
    pub fn emphasis(r: *Renderer, out: *Buffer, text: []const u8) anyerror!void {}
    pub fn image(r: *Renderer, out: *Buffer, link_text: []const u8, title: []const u8, alt: []const u8) anyerror!void {}
    pub fn lineBreak(r: *Renderer, out: *Buffer) anyerror!void {}
    pub fn link(r: *Renderer, out: *Buffer, link_text: []const u8, title: []const u8, content: []const u8) anyerror!void {}
    pub fn rawHtmlTag(r: *Renderer, out: *Buffer, tag: []const u8) anyerror!void {}
    pub fn tripleEmphasis(r: *Renderer, out: *Buffer, text: []const u8) anyerror!void {}
    pub fn footnoteRef(r: *Renderer, out: *Buffer, ref: []const u8, id: []const u8) anyerror!void {}
    pub fn entity(r: *Renderer, out: *Buffer, entity_text: []const u8) anyerror!void {}
    pub fn normalText(r: *Renderer, out: *Buffer, text: []const u8) anyerror!void {}
    pub fn documentHeader(r: *Renderer, out: *Buffer) anyerror!void {}
    pub fn documentFooter(r: *Renderer, out: *Buffer) anyerror!void {}

    const escape_quote = "&quot;";
    const escape_and = "&amp;";
    const escape_less = "&lt;";
    const escape_greater = "&gt;";
    const escape_nothing = "";
    fn escapeSingleChar(c: u8) []const u8 {
        return switch (c) {
            '"' => escape_quote,
            '&' => escape_and,
            '<' => escape_less,
            '>' => escape_greater,
            else => escape_nothing,
        };
    }

    fn attrEscape(out: *Buffer, src: []const u8) !void {
        var org: usize = 0;
        for (src) |ch, idx| {
            const e = escapeSingleChar(ch);
            if (e.len > 0) {
                if (idx > org) {
                    // copy all the normal characters since the last escape
                    try out.append(src[org..idx]);
                }
                org += idx + 1;
                try out.append(e);
            }
        }
        if (org < src.len) {
            try out.append(src[org..]);
        }
    }
};

test "HTML" {
    var h = try HTML.init(std.debug.global_allocator, 0);
}
