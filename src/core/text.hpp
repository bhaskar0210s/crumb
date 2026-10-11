// Small UTF-8 helpers and the one-line rendering of a history entry.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace crumb {

// Decodes UTF-8 without ever failing: each malformed byte becomes U+FFFD.
std::u32string decodeUtf8(std::string_view s, size_t maxChars = SIZE_MAX);

void appendUtf8(std::string& out, char32_t c);

// The longest prefix of `s` that fits in `maxBytes` without splitting a character.
std::string_view utf8Prefix(std::string_view s, size_t maxBytes);

// Folds case (Latin, Greek, Cyrillic) and Latin-1 accents, so a search for "e" finds "É".
char32_t fold(char32_t c);

// A list row: the text with line breaks, tabs and spaces at either end made visible, plus the UTF-16
// ranges of the characters a search matched.
struct Line {
    std::string text;
    std::vector<std::pair<uint32_t, uint32_t>> bold;  // UTF-16 offset, length
};

// `matches` are ascending character indices into `text`. When the first match lies far from the start, the
// line starts just before it (after an ellipsis) so it stays visible.
Line makeLine(std::u32string_view text, const std::vector<uint32_t>& matches, size_t maxChars = 400);

}  // namespace crumb
