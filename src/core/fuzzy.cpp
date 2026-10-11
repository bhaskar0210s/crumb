#include "fuzzy.hpp"

#include <algorithm>

#include "text.hpp"

namespace crumb {

namespace {

enum Class : uint8_t { Space, Delimiter, Lower, Upper, Digit, Other };

Class classify(char32_t c) {
    if (c == U' ' || c == U'\t' || c == U'\n' || c == U'\r' || c == 0xA0 || c == 0x3000 || c == 0x2028 ||
        c == 0x2029)
        return Space;
    if (c >= U'a' && c <= U'z') return Lower;
    if (c >= U'A' && c <= U'Z') return Upper;
    if (c >= U'0' && c <= U'9') return Digit;
    if (c < 0x80) return Delimiter;
    if (c >= 0xC0 && c <= 0xDE && c != 0xD7) return Upper;
    if (c >= 0xDF && c <= 0xFF && c != 0xF7) return Lower;
    return Other;
}

// Scores follow the spirit of fzf: a point value per matched character, bonuses where a match starts a
// word, and penalties for gaps.
constexpr int kMatch = 16;
constexpr int kGapStart = -3;
constexpr int kGapExtension = -1;
constexpr int kBoundaryWhite = 10;
constexpr int kBoundary = 8;
constexpr int kCamel = 7;
constexpr int kConsecutive = 4;
constexpr size_t kMaxStarts = 512;

int bonusAt(const Haystack& h, size_t i) {
    if (i == 0) return kBoundaryWhite;
    const auto prev = static_cast<Class>(h.kind[i - 1]);
    const auto cur = static_cast<Class>(h.kind[i]);
    if (cur == Space) return 0;
    if (prev == Space) return kBoundaryWhite;
    if (prev == Delimiter && cur != Delimiter) return kBoundary;
    if (prev == Lower && cur == Upper) return kCamel;
    if (prev != Digit && cur == Digit) return kCamel;
    return 0;
}

int scoreOf(const Haystack& h, const std::vector<uint32_t>& pos) {
    int score = 0;
    int chunk = 0;  // bonus of the character that opened the current run of consecutive matches
    for (size_t k = 0; k < pos.size(); ++k) {
        int bonus = bonusAt(h, pos[k]);
        if (k == 0) {
            bonus *= 2;
            chunk = bonus;
        } else if (pos[k] == pos[k - 1] + 1) {
            chunk = std::max({chunk, bonus, kConsecutive});
            bonus = chunk;
        } else {
            score += kGapStart + kGapExtension * static_cast<int>(pos[k] - pos[k - 1] - 2);
            chunk = bonus;
        }
        score += kMatch + bonus;
    }
    return score - static_cast<int>(std::min<uint32_t>(pos.front() / 16, 10));
}

// The best placement of one term, trying each occurrence of its first character as the start.
bool matchTerm(const Haystack& h, const std::u32string& term, int& best, std::vector<uint32_t>& bestPos) {
    const size_t n = h.folded.size();
    const size_t m = term.size();
    if (m > n) return false;
    const size_t maxSpan = std::max<size_t>(m * 6, 32);
    std::vector<uint32_t> pos(m);
    bool found = false;
    size_t starts = 0;
    for (size_t s = 0; s + m <= n; ++s) {
        if (h.folded[s] != term[0]) continue;
        if (++starts > kMaxStarts) break;
        pos[0] = static_cast<uint32_t>(s);
        size_t j = 1;
        const size_t limit = std::min(n, s + maxSpan);
        for (size_t i = s + 1; j < m && i < limit; ++i)
            if (h.folded[i] == term[j]) pos[j++] = static_cast<uint32_t>(i);
        if (j < m) {
            if (limit == n) break;  // the rest of the text is too short for the term
            continue;
        }
        const int score = scoreOf(h, pos);
        if (!found || score > best) {
            best = score;
            bestPos = pos;
            found = true;
        }
    }
    return found;
}

}  // namespace

Haystack prepare(std::u32string_view text) {
    Haystack h;
    h.folded.resize(text.size());
    h.kind.resize(text.size());
    for (size_t i = 0; i < text.size(); ++i) {
        h.folded[i] = fold(text[i]);
        h.kind[i] = classify(text[i]);
    }
    return h;
}

Query::Query(std::string_view utf8) {
    std::u32string term;
    for (char32_t c : decodeUtf8(utf8)) {
        if (c == U' ' || c == U'\t' || c == U'\n' || c == 0xA0 || c == 0x3000) {
            if (!term.empty()) terms_.push_back(std::move(term));
            term.clear();
        } else {
            term.push_back(fold(c));
        }
    }
    if (!term.empty()) terms_.push_back(std::move(term));
}

bool Query::match(const Haystack& text, int& score, std::vector<uint32_t>& positions) const {
    score = 0;
    positions.clear();
    std::vector<uint32_t> best;
    for (const auto& term : terms_) {
        int termScore = 0;
        if (!matchTerm(text, term, termScore, best)) return false;
        score += termScore;
        positions.insert(positions.end(), best.begin(), best.end());
    }
    std::sort(positions.begin(), positions.end());
    positions.erase(std::unique(positions.begin(), positions.end()), positions.end());
    return true;
}

}  // namespace crumb
