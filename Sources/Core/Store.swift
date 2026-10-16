// The clipboard history on disk: one small index plus each entry's own files, newest first.
//
//   <dir>/index          one line per entry, newest first
//   <dir>/<id>.txt       plain text            <dir>/<id>.png|jpg   picture
//   <dir>/<id>.rtf       formatted text        <dir>/<id>.thumb.png picture shrunk for the list
//   <dir>/<id>.html      formatted text        <dir>/<id>.files     file paths, one per line
//
// Only a short head of each entry lives in memory; everything else is read when needed.

import CommonCrypto
import Darwin

enum Kind: UInt8, Sendable {
    case text = 0, image = 1, files = 2
}

/// What an entry stores. A picture entry may also keep the text an app put next to it (such as its URL).
struct Flags: OptionSet, Sendable {
    let rawValue: UInt8
    static let text = Flags(rawValue: 1 << 0)
    static let rtf = Flags(rawValue: 1 << 1)
    static let html = Flags(rawValue: 1 << 2)
    static let image = Flags(rawValue: 1 << 3)
    static let jpeg = Flags(rawValue: 1 << 4)
}

struct Item: Sendable {
    var id: UInt64 = 0
    var kind = Kind.text
    var flags: Flags = []
    var fingerprint: UInt64 = 0         // identifies repeated copies of the same content
    var bytes: UInt64 = 0               // size of the text or picture as copied
    var width: UInt32 = 0, height: UInt32 = 0  // picture size in pixels
    var head: [UInt8] = []              // start of the text, or the file paths
}

/// Where an entry's files live. Safe to use from any thread.
struct Paths: Sendable {
    let directory: String

    func file(_ id: UInt64, _ ext: String) -> String { directory + "/" + String(id) + "." + ext }
    func imageFile(_ item: Item) -> String { file(item.id, item.flags.contains(.jpeg) ? "jpg" : "png") }
}

private let extensions = ["txt", "rtf", "html", "png", "jpg", "thumb.png", "files"]
private let header = Array("crumb 1\n".utf8)

final class Store {
    static let headBytes = 4096

    let paths: Paths
    private(set) var items: [Item] = []
    private(set) var limit = 100
    private var nextId: UInt64 = 1

    init(directory: String) {
        var dir = directory
        while dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        paths = Paths(directory: dir)
        // Every missing folder on the way, private to the user.
        let bytes = Array(dir.utf8)
        for end in bytes.indices.dropFirst() where bytes[end] == 0x2F {
            mkdir(String(decoding: bytes[..<end], as: UTF8.self), 0o700)
        }
        if !bytes.isEmpty { mkdir(dir, 0o700) }
    }

    var directory: String { paths.directory }
    func file(_ id: UInt64, _ ext: String) -> String { paths.file(id, ext) }
    func imageFile(_ item: Item) -> String { paths.imageFile(item) }

    func newId() -> UInt64 {
        defer { nextId += 1 }
        return nextId
    }

    /// Reads the index, forgets entries whose files are gone and deletes files that no entry uses. Without a
    /// readable index the history is rebuilt from the files themselves, so nothing is ever thrown away.
    func load() {
        items = []
        nextId = 1
        let index = readFile(directory + "/index")
        let indexed = index.starts(with: header)
        if indexed {
            for line in index.dropFirst(header.count).split(separator: 0x0A) {
                let fields = line.split(separator: 0x20)
                guard fields.count >= 7,
                      let id = number(fields[0], UInt64.self), id != 0,
                      let kindValue = number(fields[1], UInt8.self), let kind = Kind(rawValue: kindValue),
                      let flags = number(fields[2], UInt8.self),
                      let fingerprint = number(fields[3], UInt64.self, radix: 16),
                      let bytes = number(fields[4], UInt64.self),
                      let width = number(fields[5], UInt32.self),
                      let height = number(fields[6], UInt32.self)
                else { continue }
                var item = Item(id: id, kind: kind, flags: Flags(rawValue: flags), fingerprint: fingerprint, bytes: bytes,
                                width: width, height: height)

                // Keep only entries whose main file is still there.
                let ok: Bool
                switch item.kind {
                case .files:
                    item.head = readHead(id, "files")
                    ok = !item.head.isEmpty
                case .image:
                    ok = exists(imageFile(item))
                case .text:
                    ok = item.flags.contains(.text) && exists(file(id, "txt"))
                }
                if !ok { continue }
                if item.kind != .files && item.flags.contains(.text) { item.head = readHead(id, "txt") }
                items.append(item)
            }
        }

        // Every entry that has files in the folder, with the kinds of files it has.
        var found: [UInt64: Set<String>] = [:]
        if let d = opendir(directory) {
            while let entry = readdir(d) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                guard let first = name.utf8.first, first >= 0x30 && first <= 0x39 else {
                    if name == "index.tmp" { unlink(directory + "/" + name) }
                    continue
                }
                let digits = name.utf8.prefix { $0 >= 0x30 && $0 <= 0x39 }
                let rest = name.utf8.dropFirst(digits.count)
                guard let id = UInt64(String(decoding: digits, as: UTF8.self)), id != 0, rest.first == 0x2E else { continue }
                found[id, default: []].insert(String(decoding: rest.dropFirst(), as: UTF8.self))
            }
            closedir(d)
        }
        for id in found.keys where id < .max { nextId = max(nextId, id + 1) }

        if indexed {
            // Files that no entry uses are leftovers of a crash: delete them.
            let live = Set(items.map(\.id))
            for id in found.keys where !live.contains(id) { deleteFiles(id) }
        } else {
            // The index is missing or damaged: rebuild the history from the files, newest first.
            for id in found.keys.sorted(by: >) {
                let has = found[id]!
                var item = Item(id: id)
                if has.contains("files") {
                    let list = readFile(file(id, "files"))
                    item.kind = .files
                    item.bytes = UInt64(list.count)
                    item.fingerprint = fingerprint(list)
                    item.head = readHead(id, "files")
                } else if has.contains("png") || has.contains("jpg") {
                    item.kind = .image
                    item.flags = has.contains("png") ? .image : [.image, .jpeg]
                    let picture = readFile(imageFile(item))
                    item.bytes = UInt64(picture.count)
                    item.fingerprint = fingerprint(picture)
                    if let (width, height) = imageSize(picture) {
                        item.width = width
                        item.height = height
                    }
                    if has.contains("txt") {
                        item.flags.insert(.text)
                        item.head = readHead(id, "txt")
                    }
                } else if has.contains("txt") {
                    let text = readFile(file(id, "txt"))
                    item.kind = .text
                    item.flags = .text
                    if has.contains("rtf") { item.flags.insert(.rtf) }
                    if has.contains("html") { item.flags.insert(.html) }
                    item.bytes = UInt64(text.count)
                    item.fingerprint = fingerprint(text)
                    item.head = readHead(id, "txt")
                }
                if item.bytes == 0 || (item.kind == .image && item.width == 0) {
                    deleteFiles(id)
                    continue
                }
                items.append(item)
            }
        }
        trim()
        save()
    }

    /// Puts an entry whose files are already written on top (or at `position`). An older copy of the same
    /// content is replaced, and entries beyond the limit are deleted.
    func add(_ item: Item, at position: Int = 0) {
        var position = position
        if let i = items.firstIndex(where: { $0.fingerprint == item.fingerprint && $0.kind == item.kind && $0.id != item.id }) {
            deleteFiles(items[i].id)
            items.remove(at: i)
            if i < position { position -= 1 }
        }
        items.insert(item, at: min(position, items.count))
        trim()
        save()
    }

    func moveToTop(_ index: Int) {
        guard index > 0 && index < items.count else { return }
        items.insert(items.remove(at: index), at: 0)
        save()
    }

    func remove(_ index: Int) {
        guard index >= 0 && index < items.count else { return }
        deleteFiles(items[index].id)
        items.remove(at: index)
        save()
    }

    func clear() {
        for item in items { deleteFiles(item.id) }
        items = []
        save()
    }

    func setLimit(_ limit: Int) {
        self.limit = max(limit, 1)
        if items.count > self.limit {
            trim()
            save()
        }
    }

    /// Deletes the files of an entry that never made it into the history.
    func forget(_ id: UInt64) {
        deleteFiles(id)
    }

    private func readHead(_ id: UInt64, _ ext: String) -> [UInt8] {
        // A few spare bytes let the cut fall on a character boundary.
        utf8Prefix(readFile(file(id, ext), maxBytes: Store.headBytes + 3), maxBytes: Store.headBytes)
    }

    private func trim() {
        while items.count > limit {
            deleteFiles(items.removeLast().id)
        }
    }

    private func save() {
        var out = header
        for item in items {
            let line = String(item.id) + " " + String(item.kind.rawValue) + " " + String(item.flags.rawValue) + " "
                + hex16(item.fingerprint) + " " + String(item.bytes) + " " + String(item.width) + " " + String(item.height) + "\n"
            out += line.utf8
        }
        let tmp = directory + "/index.tmp"
        // Written next to the old one and swapped in, so a crash never leaves a half-written index.
        if writeFile(tmp, out, durable: true) { rename(tmp, directory + "/index") }
    }

    private func deleteFiles(_ id: UInt64) {
        for ext in extensions { unlink(file(id, ext)) }
    }
}

/// The text a row shows and searches: the start of a text, or the names of copied files.
func displayText(_ item: Item) -> [UInt32] {
    if item.kind != .files { return decodeUTF8(item.head) }
    var out: [UInt32] = []
    var paths = item.head.split(separator: 0x0A, omittingEmptySubsequences: false)
    if paths.count > 1 && paths.last?.isEmpty == true { paths.removeLast() }
    for path in paths {
        var name = path[...]
        if let slash = path.lastIndex(of: 0x2F), slash + 1 < path.endIndex { name = path[(slash + 1)...] }
        if !out.isEmpty { out += [0x2C, 0x20] }  // ", "
        out += decodeUTF8(Array(name))
    }
    return out
}

private func number<T: FixedWidthInteger>(_ field: ArraySlice<UInt8>, _ type: T.Type, radix: Int = 10) -> T? {
    T(String(decoding: field, as: UTF8.self), radix: radix)
}

private func hex16(_ value: UInt64) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: 16 - digits.count) + digits
}

private func exists(_ path: String) -> Bool {
    access(path, F_OK) == 0
}

/// A picture's pixel size from its PNG or JPEG header.
private func imageSize(_ data: [UInt8]) -> (UInt32, UInt32)? {
    func bigEndian(_ at: Int, _ count: Int) -> UInt32 {
        var value: UInt32 = 0
        for k in 0..<count { value = value << 8 | UInt32(data[at + k]) }
        return value
    }
    let n = data.count
    if n >= 24 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 {
        let width = bigEndian(16, 4), height = bigEndian(20, 4)
        return width != 0 && height != 0 ? (width, height) : nil
    }
    guard n >= 4 && data[0] == 0xFF && data[1] == 0xD8 else { return nil }
    var i = 2
    while i + 9 < n {
        if data[i] != 0xFF { return nil }
        let marker = data[i + 1]
        if marker == 0xFF {
            i += 1
            continue
        }
        let length = Int(bigEndian(i + 2, 2))
        if marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
            let height = bigEndian(i + 5, 2), width = bigEndian(i + 7, 2)
            return width != 0 && height != 0 ? (width, height) : nil
        }
        i += 2 + length
    }
    return nil
}

// File helpers, safe to call from any thread. Files are private to the user (mode 0600).

@discardableResult
func writeFile(_ path: String, _ bytes: UnsafeRawBufferPointer, durable: Bool = false) -> Bool {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    if fd < 0 { return false }
    var offset = 0
    while offset < bytes.count {
        let n = write(fd, bytes.baseAddress! + offset, min(bytes.count - offset, 1 << 30))
        if n < 0 {
            if errno == EINTR { continue }
            close(fd)
            unlink(path)
            return false
        }
        offset += n
    }
    if durable { fsync(fd) }
    return close(fd) == 0
}

@discardableResult
func writeFile(_ path: String, _ bytes: [UInt8], durable: Bool = false) -> Bool {
    bytes.withUnsafeBytes { writeFile(path, $0, durable: durable) }
}

func readFile(_ path: String, maxBytes: Int = .max) -> [UInt8] {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    if fd < 0 { return [] }
    defer { close(fd) }
    var out: [UInt8] = []
    var info = stat()
    if fstat(fd, &info) == 0 && info.st_size > 0 { out.reserveCapacity(min(Int(info.st_size), maxBytes)) }
    var buffer = [UInt8](repeating: 0, count: 16384)
    while out.count < maxBytes {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, min($0.count, maxBytes - out.count)) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        out += buffer[..<n]
    }
    return out
}

/// The first 64 bits of the content's SHA-256.
func fingerprint(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
    var context = CC_SHA256_CTX()
    CC_SHA256_Init(&context)
    var offset = 0
    while offset < bytes.count {
        let chunk = min(bytes.count - offset, 1 << 30)
        CC_SHA256_Update(&context, bytes.baseAddress! + offset, CC_LONG(chunk))
        offset += chunk
    }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, &context)
    var value: UInt64 = 0
    withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: digest[..<8]) }
    return value
}

func fingerprint(_ bytes: [UInt8]) -> UInt64 {
    bytes.withUnsafeBytes { fingerprint($0) }
}
