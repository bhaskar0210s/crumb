// Compares dotted version numbers such as "1.2.10" (an optional leading "v" is ignored).

func isNewerVersion(_ candidate: String, _ current: String) -> Bool {
    func numbers(_ version: String) -> [Int] {
        var bytes = Substring(version).utf8[...]
        if let first = bytes.first, first == 0x76 || first == 0x56 { bytes = bytes.dropFirst() }  // v, V
        var out: [Int] = []
        while !bytes.isEmpty {
            var value = 0
            while let c = bytes.first, c >= 0x30 && c <= 0x39 {
                let (times, o1) = value.multipliedReportingOverflow(by: 10)
                let (sum, o2) = times.addingReportingOverflow(Int(c - 0x30))
                value = o1 || o2 ? .max : sum  // absurdly long numbers saturate
                bytes = bytes.dropFirst()
            }
            while let c = bytes.first, c < 0x30 || c > 0x39 { bytes = bytes.dropFirst() }
            out.append(value)
        }
        return out
    }
    let a = numbers(candidate), b = numbers(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}
