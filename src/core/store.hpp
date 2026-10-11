// The clipboard history on disk: one small index plus each entry's own files, newest first.
//
//   <dir>/index          one line per entry, newest first
//   <dir>/<id>.txt       plain text            <dir>/<id>.png|jpg   picture
//   <dir>/<id>.rtf       formatted text        <dir>/<id>.thumb.png picture shrunk for the list
//   <dir>/<id>.html      formatted text        <dir>/<id>.files     file paths, one per line
//
// Only a short head of each entry lives in memory; everything else is read when needed.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace crumb {

enum class Kind : uint8_t { Text = 0, Image = 1, Files = 2 };

// What an entry stores. A picture entry may also keep the text an app put next to it (such as its URL).
enum : uint8_t {
    kHasText = 1 << 0,
    kHasRTF = 1 << 1,
    kHasHTML = 1 << 2,
    kHasImage = 1 << 3,
    kImageIsJPEG = 1 << 4,
};

struct Item {
    uint64_t id = 0;
    Kind kind = Kind::Text;
    uint8_t flags = 0;
    uint64_t fingerprint = 0;        // identifies repeated copies of the same content
    uint64_t bytes = 0;              // size of the text or picture as copied
    uint32_t width = 0, height = 0;  // picture size in pixels
    std::string head;                // start of the text, or the file paths
};

class Store {
public:
    static constexpr size_t kHeadBytes = 4096;

    explicit Store(std::string directory);

    // Reads the index, forgets entries whose files are gone and deletes files that no entry uses. Without a
    // readable index the history is rebuilt from the files themselves, so nothing is ever thrown away.
    void load();

    const std::vector<Item>& items() const { return items_; }
    const std::string& directory() const { return dir_; }
    size_t limit() const { return limit_; }

    // Path of one of an entry's files, such as file(7, "txt"). Safe to call from any thread.
    std::string file(uint64_t id, std::string_view ext) const;
    std::string imageFile(const Item& item) const;

    uint64_t newId() { return nextId_++; }

    // Puts an entry whose files are already written on top (or at `position`). An older copy of the same
    // content is replaced, and entries beyond the limit are deleted.
    void add(Item item, size_t position = 0);
    void moveToTop(size_t index);
    void remove(size_t index);
    void clear();
    void setLimit(size_t limit);
    // Deletes the files of an entry that never made it into the history.
    void forget(uint64_t id) const { deleteFiles(id); }

private:
    std::string readHead(uint64_t id, std::string_view ext) const;
    void trim();
    void save() const;
    void deleteFiles(uint64_t id) const;

    std::string dir_;
    std::vector<Item> items_;
    size_t limit_ = 100;
    uint64_t nextId_ = 1;
};

// File helpers, safe to call from any thread. Files are private to the user (mode 0600).
bool writeFile(const std::string& path, const void* data, size_t size, bool durable = false);
std::string readFile(const std::string& path, size_t maxBytes = SIZE_MAX);
uint64_t fingerprint(const void* data, size_t size);

}  // namespace crumb
