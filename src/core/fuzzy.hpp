// Fuzzy search: every space-separated term must appear in order (not necessarily adjacent) within a short
// stretch of the text. Matches score higher when they are consecutive, start words, or come early.

#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace crumb {

// Text prepared once and searched on every keystroke.
struct Haystack {
    std::u32string folded;      // fold() of each character
    std::vector<uint8_t> kind;  // character class of each original character
};

Haystack prepare(std::u32string_view text);

class Query {
public:
    explicit Query(std::string_view utf8);

    bool empty() const { return terms_.empty(); }

    // True when every term matches. `positions` receives the matched character indices in ascending order.
    bool match(const Haystack& text, int& score, std::vector<uint32_t>& positions) const;

private:
    std::vector<std::u32string> terms_;
};

}  // namespace crumb
