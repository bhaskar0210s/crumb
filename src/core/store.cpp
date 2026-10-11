#include "store.hpp"

#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <unordered_set>

#include "text.hpp"

namespace crumb {

namespace {

constexpr const char* kExtensions[] = {"txt", "rtf", "html", "png", "jpg", "thumb.png", "files"};

void makeDirectories(const std::string& path) {
    for (size_t i = 1; i <= path.size(); ++i) {
        if (i == path.size() || path[i] == '/') mkdir(path.substr(0, i).c_str(), 0700);
    }
}

bool exists(const std::string& path) {
    return access(path.c_str(), F_OK) == 0;
}

}  // namespace

bool writeFile(const std::string& path, const void* data, size_t size, bool durable) {
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    const auto* p = static_cast<const char*>(data);
    while (size > 0) {
        const ssize_t n = write(fd, p, std::min<size_t>(size, 1 << 30));
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            unlink(path.c_str());
            return false;
        }
        p += n;
        size -= static_cast<size_t>(n);
    }
    if (durable) fsync(fd);
    return close(fd) == 0;
}

std::string readFile(const std::string& path, size_t maxBytes) {
    std::string out;
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return out;
    struct stat st {};
    if (fstat(fd, &st) == 0 && st.st_size > 0) out.reserve(std::min<size_t>(static_cast<size_t>(st.st_size), maxBytes));
    char buffer[16384];
    while (out.size() < maxBytes) {
        const ssize_t n = read(fd, buffer, std::min(sizeof(buffer), maxBytes - out.size()));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        out.append(buffer, static_cast<size_t>(n));
    }
    close(fd);
    return out;
}

uint64_t fingerprint(const void* data, size_t size) {
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    const auto* p = static_cast<const unsigned char*>(data);
    while (size > 0) {
        const auto chunk = static_cast<CC_LONG>(std::min<size_t>(size, 1 << 30));
        CC_SHA256_Update(&ctx, p, chunk);
        p += chunk;
        size -= chunk;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    uint64_t value = 0;
    std::memcpy(&value, digest, sizeof(value));
    return value;
}

Store::Store(std::string directory) : dir_(std::move(directory)) {
    while (dir_.size() > 1 && dir_.back() == '/') dir_.pop_back();
    makeDirectories(dir_);
}

std::string Store::file(uint64_t id, std::string_view ext) const {
    std::string path = dir_;
    path += '/';
    path += std::to_string(id);
    path += '.';
    path += ext;
    return path;
}

std::string Store::imageFile(const Item& item) const {
    return file(item.id, (item.flags & kImageIsJPEG) ? "jpg" : "png");
}

namespace {

uint32_t bigEndian(const unsigned char* p, int bytes) {
    uint32_t v = 0;
    for (int i = 0; i < bytes; ++i) v = (v << 8) | p[i];
    return v;
}

// A picture's pixel size from its PNG or JPEG header.
bool imageSize(const std::string& data, uint32_t& width, uint32_t& height) {
    const auto* p = reinterpret_cast<const unsigned char*>(data.data());
    const size_t n = data.size();
    if (n >= 24 && std::memcmp(p, "\x89PNG", 4) == 0) {
        width = bigEndian(p + 16, 4);
        height = bigEndian(p + 20, 4);
        return width && height;
    }
    if (n < 4 || p[0] != 0xFF || p[1] != 0xD8) return false;
    for (size_t i = 2; i + 9 < n;) {
        if (p[i] != 0xFF) return false;
        const unsigned char marker = p[i + 1];
        if (marker == 0xFF) {
            ++i;
            continue;
        }
        const size_t length = bigEndian(p + i + 2, 2);
        if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
            height = bigEndian(p + i + 5, 2);
            width = bigEndian(p + i + 7, 2);
            return width && height;
        }
        i += 2 + length;
    }
    return false;
}

}  // namespace

std::string Store::readHead(uint64_t id, std::string_view ext) const {
    // A few spare bytes let the cut fall on a character boundary.
    return std::string(utf8Prefix(readFile(file(id, ext), kHeadBytes + 3), kHeadBytes));
}

void Store::load() {
    items_.clear();
    nextId_ = 1;
    const std::string index = readFile(dir_ + "/index");
    const bool indexed = index.rfind("crumb 1\n", 0) == 0;
    size_t pos = indexed ? index.find('\n') : std::string::npos;
    while (pos != std::string::npos && pos + 1 < index.size()) {
        const size_t end = index.find('\n', pos + 1);
        const std::string line = index.substr(pos + 1, end == std::string::npos ? std::string::npos : end - pos - 1);
        pos = end;

        Item item;
        unsigned kind = 0, flags = 0, width = 0, height = 0;
        unsigned long long id = 0, fp = 0, bytes = 0;
        if (std::sscanf(line.c_str(), "%llu %u %u %llx %llu %u %u", &id, &kind, &flags, &fp, &bytes, &width,
                        &height) != 7 ||
            id == 0 || kind > 2)
            continue;
        item.id = id;
        item.kind = static_cast<Kind>(kind);
        item.flags = static_cast<uint8_t>(flags);
        item.fingerprint = fp;
        item.bytes = bytes;
        item.width = width;
        item.height = height;

        // Keep only entries whose main file is still there.
        bool ok = false;
        if (item.kind == Kind::Files) {
            item.head = readHead(id, "files");
            ok = !item.head.empty();
        } else if (item.kind == Kind::Image) {
            ok = exists(imageFile(item));
        } else {
            ok = (item.flags & kHasText) && exists(file(id, "txt"));
        }
        if (!ok) continue;
        if (item.kind != Kind::Files && (item.flags & kHasText)) item.head = readHead(id, "txt");
        items_.push_back(std::move(item));
    }

    // Every entry that has files in the folder, with the kinds of files it has.
    std::map<uint64_t, std::set<std::string>> found;
    if (DIR* d = opendir(dir_.c_str())) {
        while (dirent* e = readdir(d)) {
            const char* name = e->d_name;
            if (name[0] < '0' || name[0] > '9') {
                if (std::strcmp(name, "index.tmp") == 0) unlink((dir_ + "/" + name).c_str());
                continue;
            }
            char* rest = nullptr;
            const uint64_t id = std::strtoull(name, &rest, 10);
            if (id && rest && *rest == '.') found[id].insert(rest + 1);
        }
        closedir(d);
    }
    for (const auto& [id, extensions] : found) nextId_ = std::max<uint64_t>(nextId_, id + 1);

    if (indexed) {
        // Files that no entry uses are leftovers of a crash: delete them.
        std::unordered_set<uint64_t> live;
        for (const auto& item : items_) live.insert(item.id);
        for (const auto& [id, extensions] : found)
            if (!live.count(id)) deleteFiles(id);
    } else {
        // The index is missing or damaged: rebuild the history from the files, newest first.
        for (auto it = found.rbegin(); it != found.rend(); ++it) {
            const uint64_t id = it->first;
            const auto& has = it->second;
            Item item;
            item.id = id;
            if (has.count("files")) {
                const std::string list = readFile(file(id, "files"));
                item.kind = Kind::Files;
                item.bytes = list.size();
                item.fingerprint = fingerprint(list.data(), list.size());
                item.head = readHead(id, "files");
            } else if (has.count("png") || has.count("jpg")) {
                item.kind = Kind::Image;
                item.flags = kHasImage | (has.count("png") ? 0 : kImageIsJPEG);
                const std::string picture = readFile(imageFile(item));
                item.bytes = picture.size();
                item.fingerprint = fingerprint(picture.data(), picture.size());
                if (!imageSize(picture, item.width, item.height)) item.width = item.height = 0;
                if (has.count("txt")) {
                    item.flags |= kHasText;
                    item.head = readHead(id, "txt");
                }
            } else if (has.count("txt")) {
                const std::string text = readFile(file(id, "txt"));
                item.kind = Kind::Text;
                item.flags = kHasText | (has.count("rtf") ? kHasRTF : 0) | (has.count("html") ? kHasHTML : 0);
                item.bytes = text.size();
                item.fingerprint = fingerprint(text.data(), text.size());
                item.head = readHead(id, "txt");
            }
            if (item.bytes == 0 || (item.kind == Kind::Image && item.width == 0)) {
                deleteFiles(id);
                continue;
            }
            items_.push_back(std::move(item));
        }
    }
    trim();
    save();
}

void Store::add(Item item, size_t position) {
    for (size_t i = 0; i < items_.size(); ++i) {
        if (items_[i].fingerprint == item.fingerprint && items_[i].kind == item.kind && items_[i].id != item.id) {
            deleteFiles(items_[i].id);
            items_.erase(items_.begin() + static_cast<std::ptrdiff_t>(i));
            if (i < position) --position;
            break;
        }
    }
    items_.insert(items_.begin() + static_cast<std::ptrdiff_t>(std::min(position, items_.size())), std::move(item));
    trim();
    save();
}

void Store::moveToTop(size_t index) {
    if (index == 0 || index >= items_.size()) return;
    std::rotate(items_.begin(), items_.begin() + static_cast<std::ptrdiff_t>(index),
                items_.begin() + static_cast<std::ptrdiff_t>(index) + 1);
    save();
}

void Store::remove(size_t index) {
    if (index >= items_.size()) return;
    deleteFiles(items_[index].id);
    items_.erase(items_.begin() + static_cast<std::ptrdiff_t>(index));
    save();
}

void Store::clear() {
    for (const auto& item : items_) deleteFiles(item.id);
    items_.clear();
    save();
}

void Store::setLimit(size_t limit) {
    limit_ = std::max<size_t>(limit, 1);
    if (items_.size() > limit_) {
        trim();
        save();
    }
}

void Store::trim() {
    while (items_.size() > limit_) {
        deleteFiles(items_.back().id);
        items_.pop_back();
    }
}

void Store::save() const {
    std::string out = "crumb 1\n";
    char line[160];
    for (const auto& item : items_) {
        std::snprintf(line, sizeof(line), "%" PRIu64 " %u %u %016" PRIx64 " %" PRIu64 " %u %u\n", item.id,
                      static_cast<unsigned>(item.kind), static_cast<unsigned>(item.flags), item.fingerprint,
                      item.bytes, item.width, item.height);
        out += line;
    }
    const std::string tmp = dir_ + "/index.tmp";
    // Written next to the old one and swapped in, so a crash never leaves a half-written index.
    if (writeFile(tmp, out.data(), out.size(), true)) rename(tmp.c_str(), (dir_ + "/index").c_str());
}

void Store::deleteFiles(uint64_t id) const {
    for (const char* ext : kExtensions) unlink(file(id, ext).c_str());
}

}  // namespace crumb
