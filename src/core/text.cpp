#include "text.hpp"

#include <algorithm>

namespace crumb {

std::u32string decodeUtf8(std::string_view s, size_t maxChars) {
    std::u32string out;
    out.reserve(std::min(s.size(), maxChars));
    const auto* p = reinterpret_cast<const unsigned char*>(s.data());
    const auto* end = p + s.size();
    while (p < end && out.size() < maxChars) {
        const unsigned char c = *p;
        char32_t cp;
        int len;
        if (c < 0x80) {
            out.push_back(c);
            ++p;
            continue;
        } else if ((c & 0xE0) == 0xC0) {
            cp = c & 0x1F;
            len = 2;
        } else if ((c & 0xF0) == 0xE0) {
            cp = c & 0x0F;
            len = 3;
        } else if ((c & 0xF8) == 0xF0) {
            cp = c & 0x07;
            len = 4;
        } else {
            out.push_back(0xFFFD);
            ++p;
            continue;
        }
        bool ok = end - p >= len;
        for (int i = 1; ok && i < len; ++i) {
            ok = (p[i] & 0xC0) == 0x80;
            cp = (cp << 6) | (p[i] & 0x3F);
        }
        const bool overlong = (len == 2 && cp < 0x80) || (len == 3 && cp < 0x800) || (len == 4 && cp < 0x10000);
        if (!ok || overlong || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
            out.push_back(0xFFFD);
            ++p;
            continue;
        }
        out.push_back(cp);
        p += len;
    }
    return out;
}

void appendUtf8(std::string& out, char32_t c) {
    if (c < 0x80) {
        out.push_back(static_cast<char>(c));
    } else if (c < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (c >> 6)));
        out.push_back(static_cast<char>(0x80 | (c & 0x3F)));
    } else if (c < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (c >> 12)));
        out.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (c & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (c >> 18)));
        out.push_back(static_cast<char>(0x80 | ((c >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (c & 0x3F)));
    }
}

std::string_view utf8Prefix(std::string_view s, size_t maxBytes) {
    if (s.size() <= maxBytes) return s;
    size_t n = maxBytes;
    while (n > 0 && (static_cast<unsigned char>(s[n]) & 0xC0) == 0x80) --n;
    return s.substr(0, n);
}

char32_t fold(char32_t c) {
    if (c < 0x80) return (c >= 'A' && c <= 'Z') ? c + 32 : c;
    if (c >= 0xC0 && c <= 0xFF) {
        // Base letters for U+00C0…U+00FF; '*' keeps × and ÷ as they are.
        static constexpr char kBase[] = "aaaaaaaceeeeiiiidnooooo*ouuuuyts"
                                        "aaaaaaaceeeeiiiidnooooo*ouuuuyty";
        const char base = kBase[c - 0xC0];
        return base == '*' ? c : static_cast<char32_t>(base);
    }
    if (c >= 0x391 && c <= 0x3A9) return c + 32;  // Greek capitals
    if (c >= 0x410 && c <= 0x42F) return c + 32;  // Cyrillic capitals
    if (c >= 0x400 && c <= 0x40F) return c + 80;  // Cyrillic Ѐ…Џ
    return c;
}

Line makeLine(std::u32string_view text, const std::vector<uint32_t>& matches, size_t maxChars) {
    Line line;
    size_t start = 0;
    if (!matches.empty() && matches.front() > 40) start = matches.front() - 12;

    // Spaces at either end would be invisible, so they are drawn as dots.
    size_t lead = 0;
    if (start == 0)
        while (lead < text.size() && text[lead] == U' ') ++lead;
    size_t trail = text.size();
    while (trail > lead && text[trail - 1] == U' ') --trail;

    uint32_t utf16 = 0;
    auto emit = [&](char32_t c, bool bold) {
        appendUtf8(line.text, c);
        const uint32_t units = c > 0xFFFF ? 2 : 1;
        if (bold) {
            if (!line.bold.empty() && line.bold.back().first + line.bold.back().second == utf16)
                line.bold.back().second += units;
            else
                line.bold.emplace_back(utf16, units);
        }
        utf16 += units;
    };

    if (start > 0) emit(U'…', false);
    size_t m = 0;
    while (m < matches.size() && matches[m] < start) ++m;
    size_t shown = 0;
    bool carry = false;  // a match on the \r of \r\n lands on the ⏎ drawn for the pair
    for (size_t i = start; i < text.size() && shown < maxChars; ++i) {
        bool hit = carry;
        carry = false;
        if (m < matches.size() && matches[m] == i) {
            hit = true;
            ++m;
        }
        char32_t c = text[i];
        if (c == U'\r' && i + 1 < text.size() && text[i + 1] == U'\n') {
            carry = hit;
            continue;
        }
        if (c == U'\n' || c == U'\r' || c == 0x2028 || c == 0x2029)
            c = U'⏎';
        else if (c == U'\t')
            c = U'⇥';
        else if (c == U' ' && (i < lead || i >= trail))
            c = U'·';
        else if (c < 0x20 || c == 0x7F)
            continue;
        emit(c, hit);
        ++shown;
    }
    return line;
}

}  // namespace crumb
