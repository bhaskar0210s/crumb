// Compares dotted version numbers such as "1.2.10" (an optional leading "v" is ignored).

#pragma once

#include <string_view>

namespace crumb {

inline bool isNewerVersion(std::string_view candidate, std::string_view current) {
    auto next = [](std::string_view& s) {
        long value = 0;
        while (!s.empty() && s.front() >= '0' && s.front() <= '9') {
            value = value * 10 + (s.front() - '0');
            s.remove_prefix(1);
        }
        while (!s.empty() && (s.front() < '0' || s.front() > '9')) s.remove_prefix(1);
        return value;
    };
    if (!candidate.empty() && (candidate.front() == 'v' || candidate.front() == 'V')) candidate.remove_prefix(1);
    if (!current.empty() && (current.front() == 'v' || current.front() == 'V')) current.remove_prefix(1);
    while (!candidate.empty() || !current.empty()) {
        const long a = next(candidate), b = next(current);
        if (a != b) return a > b;
    }
    return false;
}

}  // namespace crumb
