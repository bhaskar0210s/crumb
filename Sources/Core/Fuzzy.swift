// Fuzzy search: every space-separated term must appear in order (not necessarily adjacent) within a short stretch
// of the text. Matches score higher when they are consecutive, start words, or come early.

/// Text prepared once and searched on every keystroke.
struct Haystack {
    var folded: [UInt32]  // fold() of each character
    var kind: [UInt8]     // character class of each original character
}

private let space: UInt8 = 0, delimiter: UInt8 = 1, lower: UInt8 = 2, upper: UInt8 = 3, digit: UInt8 = 4, other: UInt8 = 5

private func classify(_ c: UInt32) -> UInt8 {
    switch c {
    case 0x20, 0x09, 0x0A, 0x0D, 0xA0, 0x3000, 0x2028, 0x2029: return space
    case 0x61...0x7A: return lower
    case 0x41...0x5A: return upper
    case 0x30...0x39: return digit
    case ..<0x80: return delimiter
    case 0xC0...0xDE where c != 0xD7: return upper
    case 0xDF...0xFF where c != 0xF7: return lower
    default: return other
    }
}

// Scores follow the spirit of fzf: a point value per matched character, bonuses where a match starts a word, and
// penalties for gaps.
private let matchPoints = 16
private let gapStart = -3
private let gapExtension = -1
private let boundaryWhite = 10
private let boundary = 8
private let camel = 7
private let consecutive = 4
private let maxStarts = 512

private func bonus(_ kind: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int {
    if i == 0 { return boundaryWhite }
    let previous = kind[i - 1], current = kind[i]
    if current == space { return 0 }
    if previous == space { return boundaryWhite }
    if previous == delimiter && current != delimiter { return boundary }
    if previous == lower && current == upper { return camel }
    if previous != digit && current == digit { return camel }
    return 0
}

private func score(_ kind: UnsafeBufferPointer<UInt8>, _ positions: [Int]) -> Int {
    var total = 0
    var chunk = 0  // bonus of the character that opened the current run of consecutive matches
    for k in positions.indices {
        var b = bonus(kind, positions[k])
        if k == 0 {
            b *= 2
            chunk = b
        } else if positions[k] == positions[k - 1] + 1 {
            chunk = max(chunk, b, consecutive)
            b = chunk
        } else {
            total += gapStart + gapExtension * (positions[k] - positions[k - 1] - 2)
            chunk = b
        }
        total += matchPoints + b
    }
    return total - min(positions[0] / 16, 10)
}

/// The best placement of one term, trying each occurrence of its first character as the start.
private func matchTerm(_ h: Haystack, _ term: [UInt32], best: inout Int, bestPositions: inout [Int]) -> Bool {
    let n = h.folded.count, m = term.count
    if m > n { return false }
    let maxSpan = max(m * 6, 32)
    var positions = [Int](repeating: 0, count: m)
    var found = false
    var starts = 0
    h.folded.withUnsafeBufferPointer { folded in
        h.kind.withUnsafeBufferPointer { kind in
            var s = 0
            while s + m <= n {
                defer { s += 1 }
                if folded[s] != term[0] { continue }
                starts += 1
                if starts > maxStarts { break }
                positions[0] = s
                var j = 1
                let limit = min(n, s + maxSpan)
                var i = s + 1
                while j < m && i < limit {
                    if folded[i] == term[j] {
                        positions[j] = i
                        j += 1
                    }
                    i += 1
                }
                if j < m {
                    if limit == n { break }  // the rest of the text is too short for the term
                    continue
                }
                let value = score(kind, positions)
                if !found || value > best {
                    best = value
                    bestPositions = positions
                    found = true
                }
            }
        }
    }
    return found
}

func prepare(_ text: [UInt32]) -> Haystack {
    Haystack(folded: text.map(fold), kind: text.map(classify))
}

struct Query {
    private var terms: [[UInt32]] = []

    init(_ utf8: [UInt8]) {
        var term: [UInt32] = []
        for c in decodeUTF8(utf8) {
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0xA0 || c == 0x3000 {
                if !term.isEmpty { terms.append(term) }
                term.removeAll()
            } else {
                term.append(fold(c))
            }
        }
        if !term.isEmpty { terms.append(term) }
    }

    init(_ text: String) {
        self.init(Array(text.utf8))
    }

    var isEmpty: Bool { terms.isEmpty }

    /// True when every term matches. `positions` receives the matched character indices in ascending order.
    func match(_ text: Haystack, score: inout Int, positions: inout [UInt32]) -> Bool {
        score = 0
        positions.removeAll(keepingCapacity: true)
        var best: [Int] = []
        for term in terms {
            var termScore = 0
            if !matchTerm(text, term, best: &termScore, bestPositions: &best) { return false }
            score += termScore
            for p in best { positions.append(UInt32(p)) }
        }
        positions.sort()
        var unique = 0
        for k in positions.indices where unique == 0 || positions[unique - 1] != positions[k] {
            positions[unique] = positions[k]
            unique += 1
        }
        positions.removeLast(positions.count - unique)
        return true
    }
}
