// Unit tests for the core: `make test` (built with AddressSanitizer).

import Darwin

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ what: String = "", file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        fputs("\(file):\(line): FAILED \(what)\n", stderr)
    }
}

func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

func listDir(_ dir: String) -> Set<String> {
    var names = Set<String>()
    if let d = opendir(dir) {
        while let entry = readdir(d) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if !name.hasPrefix(".") { names.insert(name) }
        }
        closedir(d)
    }
    return names
}

func tempDir() -> String {
    var pattern = Array("/tmp/crumb-tests-XXXXXX".utf8CString)
    guard let dir = mkdtemp(&pattern) else { return "" }
    return String(cString: dir) + "/history"
}

func removeDir(_ dir: String) {
    for name in listDir(dir) { unlink(dir + "/" + name) }
    rmdir(dir)
    rmdir(String(dir[..<dir.lastIndex(of: "/")!]))
}

/// Writes a text entry the way the app does: files first, then the index.
@discardableResult
func addText(_ store: Store, _ text: String) -> Item {
    let data = bytes(text)
    var item = Item()
    item.id = store.newId()
    item.kind = .text
    item.flags = .text
    item.bytes = UInt64(data.count)
    item.fingerprint = fingerprint(data)
    item.head = utf8Prefix(data, maxBytes: Store.headBytes)
    writeFile(store.file(item.id, "txt"), data)
    store.add(item)
    return item
}

func head(_ item: Item) -> String { String(decoding: item.head, as: UTF8.self) }

func testUTF8() {
    check(decodeUTF8(bytes("abc")) == scalars("abc"))
    check(decodeUTF8(bytes("héllo")) == scalars("héllo"))
    check(decodeUTF8([0xF0, 0x9F, 0x8D, 0x9E]) == scalars("🍞"))
    check(decodeUTF8([0x61, 0xFF, 0x7A]) == [0x61, 0xFFFD, 0x7A], "invalid byte")
    check(decodeUTF8([0x61, 0xE2, 0x82]) == [0x61, 0xFFFD, 0xFFFD], "truncated sequence")
    check(decodeUTF8([0xC0, 0xAF]) == [0xFFFD, 0xFFFD], "overlong")
    check(decodeUTF8([0xED, 0xA0, 0x80]) == [0xFFFD, 0xFFFD, 0xFFFD], "UTF-16 surrogate")
    check(decodeUTF8(bytes("abcdef"), maxChars: 3) == scalars("abc"))
    var out: [UInt8] = []
    for c in scalars("Crumb 🍞 é ж") { appendUTF8(&out, c) }
    check(out == bytes("Crumb 🍞 é ж"))
    check(utf8Prefix(bytes("héllo"), maxBytes: 2) == bytes("h"), "never splits é")
    check(utf8Prefix(bytes("héllo"), maxBytes: 3) == bytes("hé"))
    check(utf8Prefix(bytes("abc"), maxBytes: 10) == bytes("abc"))
    check(fold(0x41) == 0x61)
    check(fold(scalars("É")[0]) == 0x65)
    check(fold(scalars("ß")[0]) == 0x73)
    check(fold(scalars("Ж")[0]) == scalars("ж")[0])
    check(fold(scalars("Ω")[0]) == scalars("ω")[0])
    check(fold(scalars("×")[0]) == scalars("×")[0])
    check(fold(0x37) == 0x37)
}

func testLine() {
    func plain(_ s: String) -> String { makeLine(scalars(s), matches: []).text }
    check(plain("one\ntwo") == "one⏎two")
    check(plain("one\r\ntwo") == "one⏎two")
    check(plain("a\tb") == "a⇥b")
    check(plain("  padded  ") == "··padded··")
    check(plain("in side") == "in side")
    check(plain("   ") == "···")
    check(plain("bell\u{07}") == "bell")
    check(makeLine(scalars("abcdef"), matches: [], maxChars: 3).text == "abc")

    // Bold ranges are UTF-16 offsets: the emoji takes two units.
    let line = makeLine(scalars("🍞 bread"), matches: [2, 3])
    check(line.text == "🍞 bread")
    check(line.bold.count == 1)
    check(line.bold.first?.offset == 3 && line.bold.first?.length == 2)

    // A match on \r\n lands on its ⏎.
    let crlf = makeLine(scalars("a\r\nb"), matches: [1])
    check(crlf.text == "a⏎b")
    check(crlf.bold.count == 1 && crlf.bold.first?.offset == 1)

    // A far-away match is brought into view after an ellipsis.
    let far = makeLine(scalars(String(repeating: "x", count: 100) + "needle"), matches: [100, 101])
    check(far.text.hasPrefix("…"))
    check(far.text.contains("needle"))
    check(far.bold.count == 1 && far.bold.first?.offset == 13)
}

func matches(_ query: String, _ text: String, score: UnsafeMutablePointer<Int>? = nil, positions: UnsafeMutablePointer<[UInt32]>? = nil) -> Bool {
    let q = Query(query)
    let h = prepare(scalars(text))
    var s = 0
    var p: [UInt32] = []
    let ok = q.match(h, score: &s, positions: &p)
    score?.pointee = s
    positions?.pointee = p
    return ok
}

func testFuzzy() {
    check(Query("").isEmpty)
    check(Query("   ").isEmpty)
    check(matches("gp", "git push"))
    check(matches("GITPUSH", "git push origin"))
    check(matches("cafe", "Café au lait"))
    check(!matches("xyz", "git push"))
    check(!matches("pg", "git push"), "order matters")
    check(matches("push git", "git push"), "terms can come in any order")
    check(!matches("push zzz", "git push"))

    var positions: [UInt32] = []
    check(matches("gp", "git push", positions: &positions))
    check(positions == [0, 4])

    // Letters scattered across a long text are not a match.
    check(!matches("ab", "a" + String(repeating: "-", count: 100) + "b"))

    // Consecutive and word-start matches beat scattered ones; earlier beats later.
    var tight = 0, loose = 0, early = 0, late = 0
    _ = matches("crumb", "crumb.txt", score: &tight)
    _ = matches("crumb", "cream rumba b", score: &loose)
    check(tight > loose)
    _ = matches("main", "main.cpp and more", score: &early)
    _ = matches("main", "some text before the main.cpp", score: &late)
    check(early > late)
    var atBoundary = 0, inner = 0
    _ = matches("rd", "read data", score: &atBoundary)
    _ = matches("rd", "herdsman", score: &inner)
    check(atBoundary > inner)
}

func testStore() {
    let dir = tempDir()
    check(!dir.isEmpty)
    do {
        let store = Store(directory: dir)
        store.load()
        check(store.items.isEmpty)
        addText(store, "first")
        addText(store, "second")
        addText(store, "third")
        check(store.items.count == 3)
        check(head(store.items[0]) == "third")

        // Copying something again moves it to the top instead of duplicating it.
        let again = addText(store, "first")
        check(store.items.count == 3)
        check(head(store.items[0]) == "first")
        check(store.items[0].id == again.id)

        store.moveToTop(2)
        check(head(store.items[0]) == "second")
        store.remove(0)
        check(store.items.count == 2)
        check(head(store.items[0]) == "first")
    }
    do {
        // Everything survives a restart, in order.
        let store = Store(directory: dir)
        store.load()
        check(store.items.count == 2)
        check(head(store.items[0]) == "first")
        check(head(store.items[1]) == "third")
        check(store.items[0].flags == .text)
        check(readFile(store.file(store.items[0].id, "txt")) == bytes("first"))

        // New ids never reuse old ones.
        let item = addText(store, "fourth")
        check(item.id > store.items[1].id && item.id > store.items[2].id)

        // The limit trims the oldest entries and their files.
        store.setLimit(2)
        check(store.items.count == 2)
        check(head(store.items[1]) == "first")
        check(listDir(dir).contains(String(store.items[0].id) + ".txt"))
        check(listDir(dir).count == 3, "index + two texts")

        // Big texts are stored in full; only the head stays in memory.
        let big = String(repeating: "z", count: 3 << 20)
        addText(store, big)
        check(store.items[0].head.count == Store.headBytes)
        check(store.items[0].bytes == UInt64(big.utf8.count))
        check(readFile(store.file(store.items[0].id, "txt")) == bytes(big))
    }
    do {
        // Entries whose files vanished are dropped; stray files are deleted.
        let store = Store(directory: dir)
        store.load()
        let victim = store.items[1].id
        unlink(store.file(victim, "txt"))
        writeFile(dir + "/999.txt", bytes("stray"))
        writeFile(dir + "/index.tmp", bytes("x"))
        store.load()
        check(store.items.count == 1)
        check(!listDir(dir).contains("999.txt"))
        check(!listDir(dir).contains("index.tmp"))
        check(store.newId() > 999)

        store.clear()
        check(store.items.isEmpty)
        check(listDir(dir) == ["index"])
    }
    do {
        let store = Store(directory: dir)
        store.load()
        check(store.items.isEmpty)
        var info = stat()
        check(stat(dir, &info) == 0 && info.st_mode & 0o777 == 0o700)
        check(stat(dir + "/index", &info) == 0 && info.st_mode & 0o777 == 0o600)
    }
    removeDir(dir)
}

func testStoreRecovery() {
    let dir = tempDir()
    do {
        // A history larger than the default limit survives a restart when the limit is set first.
        let store = Store(directory: dir)
        store.setLimit(500)
        store.load()
        for i in 0..<150 { addText(store, "entry \(i)") }
        let again = Store(directory: dir)
        again.setLimit(500)
        again.load()
        check(again.items.count == 150)
        again.clear()
    }
    do {
        let store = Store(directory: dir)
        store.load()
        addText(store, "oldest")
        // A picture: just enough of a PNG header for its size to be read back.
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52,
                            0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38]
        png += [UInt8](repeating: 0, count: 100)
        var picture = Item()
        picture.id = store.newId()
        picture.kind = .image
        picture.flags = .image
        picture.bytes = UInt64(png.count)
        picture.width = 1920
        picture.height = 1080
        picture.fingerprint = fingerprint(png)
        writeFile(store.file(picture.id, "png"), png)
        store.add(picture)
        let paths = bytes("/tmp/a.txt\n/tmp/b.txt")
        var files = Item()
        files.id = store.newId()
        files.kind = .files
        files.bytes = UInt64(paths.count)
        files.fingerprint = fingerprint(paths)
        files.head = paths
        writeFile(store.file(files.id, "files"), paths)
        store.add(files)
        addText(store, "newest")
        check(store.items.count == 4)
    }
    for damage in ["missing", "empty", "garbage"] {
        // Without a readable index nothing is lost: the history comes back from the files, newest first.
        switch damage {
        case "missing": unlink(dir + "/index")
        case "empty": writeFile(dir + "/index", [])
        default: writeFile(dir + "/index", bytes("nonsense\n1 2 3"))
        }
        let store = Store(directory: dir)
        store.load()
        check(store.items.count == 4, damage)
        if store.items.count != 4 { continue }
        check(head(store.items[0]) == "newest")
        check(store.items[1].kind == .files && head(store.items[1]) == "/tmp/a.txt\n/tmp/b.txt")
        check(store.items[2].kind == .image && store.items[2].width == 1920 && store.items[2].height == 1080)
        check(head(store.items[3]) == "oldest" && store.items[3].kind == .text)
        // Fingerprints are rebuilt, so copying the same text again still folds into one entry.
        check(store.items[3].fingerprint == fingerprint(bytes("oldest")))
    }
    do {
        // Heads end on a character boundary even when the cut falls inside one.
        let store = Store(directory: dir)
        store.load()
        let text = String(repeating: "a", count: Store.headBytes - 1) + "é and more"
        addText(store, text)
        let again = Store(directory: dir)
        again.load()
        check(head(again.items[0]) == String(repeating: "a", count: Store.headBytes - 1))
        check(readFile(again.file(again.items[0].id, "txt")) == bytes(text))

        // An entry can go below the top (a copy that finished saving after a newer one).
        var late = Item()
        late.id = again.newId()
        late.kind = .text
        late.flags = .text
        late.head = bytes("late")
        late.bytes = 4
        late.fingerprint = fingerprint(bytes("late"))
        writeFile(again.file(late.id, "txt"), bytes("late"))
        again.add(late, at: 1)
        check(head(again.items[1]) == "late")
        again.clear()
    }
    removeDir(dir)
}

func testFixes() {
    // A version number longer than Int saturates instead of crashing.
    check(isNewerVersion("v2.0.0-build.202610161234567890123", "2.0.0"))
    check(!isNewerVersion("1.99999999999999999999999", "2.0"))

    // Files entries: names only, and a trailing line break adds no empty name.
    var files = Item()
    files.kind = .files
    files.head = bytes("/a/x.txt\n/b/y.txt\n")
    check(String(String.UnicodeScalarView(displayText(files).compactMap(Unicode.Scalar.init))) == "x.txt, y.txt")
    files.head = bytes("/a/x.txt\n")
    check(String(String.UnicodeScalarView(displayText(files).compactMap(Unicode.Scalar.init))) == "x.txt")

    let dir = tempDir()
    do {
        // The largest possible id in the folder doesn't overflow the next id.
        let store = Store(directory: dir)
        writeFile(dir + "/18446744073709551615.txt", bytes("edge"))
        store.load()
        check(store.items.count == 1)
        addText(store, "after the edge")
        check(store.items.count == 2)
        store.clear()
    }
    removeDir(dir)

    // A relative folder is created where it is named.
    let base = tempDir()
    let parent = String(base[..<base.lastIndex(of: "/")!])
    chdir(parent)
    let relative = Store(directory: "nested/history")
    relative.load()
    var info = stat()
    check(stat(parent + "/nested/history/index", &info) == 0)
    unlink(parent + "/nested/history/index")
    rmdir(parent + "/nested/history")
    rmdir(parent + "/nested")
    rmdir(parent)
}

func testVersion() {
    check(isNewerVersion("1.0.1", "1.0.0"))
    check(isNewerVersion("v1.10.0", "1.9.9"))
    check(isNewerVersion("2", "1.9"))
    check(!isNewerVersion("1.0.0", "1.0.0"))
    check(!isNewerVersion("v1.0", "1.0.0"))
    check(!isNewerVersion("0.9.9", "1.0.0"))
    check(!isNewerVersion("", "1.0.0"))
}

testUTF8()
testLine()
testFuzzy()
testStore()
testStoreRecovery()
testVersion()
testFixes()
print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
