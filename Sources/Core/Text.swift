// Small UTF-8 helpers and the one-line rendering of a history entry. Text is kept as UTF-8 bytes on disk and in
// memory, and as Unicode scalar values (UTF-32) while it is searched or laid out in a row.

/// Decodes UTF-8 without ever failing: each malformed byte becomes U+FFFD.
func decodeUTF8(_ bytes: [UInt8], maxChars: Int = .max) -> [UInt32] {
    bytes.withUnsafeBufferPointer { decodeUTF8($0, maxChars: maxChars) }
}

func decodeUTF8(_ s: UnsafeBufferPointer<UInt8>, maxChars: Int = .max) -> [UInt32] {
    var out: [UInt32] = []
    out.reserveCapacity(min(s.count, maxChars))
    var i = 0
    let n = s.count
    while i < n && out.count < maxChars {
        let c = s[i]
        if c < 0x80 {
            out.append(UInt32(c))
            i += 1
            continue
        }
        var cp: UInt32
        let length: Int
        if c & 0xE0 == 0xC0 {
            cp = UInt32(c & 0x1F)
            length = 2
        } else if c & 0xF0 == 0xE0 {
            cp = UInt32(c & 0x0F)
            length = 3
        } else if c & 0xF8 == 0xF0 {
            cp = UInt32(c & 0x07)
            length = 4
        } else {
            out.append(0xFFFD)
            i += 1
            continue
        }
        var ok = n - i >= length
        var k = 1
        while ok && k < length {
            ok = s[i + k] & 0xC0 == 0x80
            cp = cp << 6 | UInt32(s[i + k] & 0x3F)
            k += 1
        }
        let overlong = (length == 2 && cp < 0x80) || (length == 3 && cp < 0x800) || (length == 4 && cp < 0x10000)
        if !ok || overlong || cp > 0x10FFFF || (0xD800...0xDFFF).contains(cp) {
            out.append(0xFFFD)
            i += 1
            continue
        }
        out.append(cp)
        i += length
    }
    return out
}

func appendUTF8(_ out: inout [UInt8], _ c: UInt32) {
    if c < 0x80 {
        out.append(UInt8(c))
    } else if c < 0x800 {
        out.append(UInt8(0xC0 | c >> 6))
        out.append(UInt8(0x80 | c & 0x3F))
    } else if c < 0x10000 {
        out.append(UInt8(0xE0 | c >> 12))
        out.append(UInt8(0x80 | c >> 6 & 0x3F))
        out.append(UInt8(0x80 | c & 0x3F))
    } else {
        out.append(UInt8(0xF0 | c >> 18))
        out.append(UInt8(0x80 | c >> 12 & 0x3F))
        out.append(UInt8(0x80 | c >> 6 & 0x3F))
        out.append(UInt8(0x80 | c & 0x3F))
    }
}

/// The length of the longest prefix of `s` that fits in `maxBytes` without splitting a character.
func utf8PrefixLength(_ s: UnsafeBufferPointer<UInt8>, maxBytes: Int) -> Int {
    if s.count <= maxBytes { return s.count }
    var n = maxBytes
    while n > 0 && s[n] & 0xC0 == 0x80 { n -= 1 }
    return n
}

func utf8Prefix(_ s: [UInt8], maxBytes: Int) -> [UInt8] {
    let n = s.withUnsafeBufferPointer { utf8PrefixLength($0, maxBytes: maxBytes) }
    return n == s.count ? s : Array(s[..<n])
}

/// Folds case (Latin, Greek, Cyrillic) and Latin-1 accents, so a search for "e" finds "É".
func fold(_ c: UInt32) -> UInt32 {
    if c < 0x80 { return c >= 0x41 && c <= 0x5A ? c + 32 : c }
    if c >= 0xC0 && c <= 0xFF {
        // Base letters for U+00C0…U+00FF; "*" keeps × and ÷ as they are.
        let base = latinBase[Int(c - 0xC0)]
        return base == 0x2A ? c : UInt32(base)
    }
    if c >= 0x391 && c <= 0x3A9 { return c + 32 }  // Greek capitals
    if c >= 0x410 && c <= 0x42F { return c + 32 }  // Cyrillic capitals
    if c >= 0x400 && c <= 0x40F { return c + 80 }  // Cyrillic Ѐ…Џ
    return c
}

private let latinBase = Array("aaaaaaaceeeeiiiidnooooo*ouuuuytsaaaaaaaceeeeiiiidnooooo*ouuuuyty".utf8)

/// A list row: the text with line breaks, tabs and spaces at either end made visible, plus the UTF-16 ranges
/// (offset, length) of the characters a search matched.
struct Line {
    var text = ""
    var bold: [(offset: Int, length: Int)] = []
}

/// `matches` are ascending indices into `text`. When the first match lies far from the start, the line starts
/// just before it (after an ellipsis) so it stays visible.
func makeLine(_ text: [UInt32], matches: [UInt32], maxChars: Int = 400) -> Line {
    var line = Line()
    var start = 0
    if let first = matches.first, first > 40 { start = Int(first) - 12 }

    // Spaces at either end would be invisible, so they are drawn as dots.
    var lead = 0
    if start == 0 {
        while lead < text.count && text[lead] == 0x20 { lead += 1 }
    }
    var trail = text.count
    while trail > lead && text[trail - 1] == 0x20 { trail -= 1 }

    var utf16 = 0
    var scalars = String.UnicodeScalarView()
    func emit(_ c: UInt32, bold: Bool) {
        scalars.append(Unicode.Scalar(c) ?? "\u{FFFD}")
        let units = c > 0xFFFF ? 2 : 1
        if bold {
            if let last = line.bold.last, last.offset + last.length == utf16 {
                line.bold[line.bold.count - 1].length += units
            } else {
                line.bold.append((utf16, units))
            }
        }
        utf16 += units
    }

    if start > 0 { emit(0x2026, bold: false) }  // …
    var m = 0
    while m < matches.count && Int(matches[m]) < start { m += 1 }
    var shown = 0
    var carry = false  // a match on the \r of \r\n lands on the ⏎ drawn for the pair
    var i = start
    while i < text.count && shown < maxChars {
        defer { i += 1 }
        var hit = carry
        carry = false
        if m < matches.count && Int(matches[m]) == i {
            hit = true
            m += 1
        }
        var c = text[i]
        if c == 0x0D && i + 1 < text.count && text[i + 1] == 0x0A {
            carry = hit
            continue
        }
        if c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029 {
            c = 0x23CE  // ⏎
        } else if c == 0x09 {
            c = 0x21E5  // ⇥
        } else if c == 0x20 && (i < lead || i >= trail) {
            c = 0xB7  // ·
        } else if c < 0x20 || c == 0x7F {
            continue
        }
        emit(c, bold: hit)
        shown += 1
    }
    line.text = String(scalars)
    return line
}
