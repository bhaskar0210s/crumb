// Unit tests for the core: `make test` (built with AddressSanitizer and UBSan).

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <set>
#include <string>

#include "../src/core/fuzzy.hpp"
#include "../src/core/store.hpp"
#include "../src/core/text.hpp"
#include "../src/core/version.hpp"

namespace {

int failures = 0;
int checks = 0;

#define CHECK(cond)                                                       \
    do {                                                                  \
        ++checks;                                                         \
        if (!(cond)) {                                                    \
            ++failures;                                                   \
            std::fprintf(stderr, "%s:%d: FAILED %s\n", __FILE__, __LINE__, #cond); \
        }                                                                 \
    } while (0)

std::string utf8(std::u32string_view s) {
    std::string out;
    for (char32_t c : s) crumb::appendUtf8(out, c);
    return out;
}

std::set<std::string> listDir(const std::string& dir) {
    std::set<std::string> names;
    if (DIR* d = opendir(dir.c_str())) {
        while (dirent* e = readdir(d))
            if (e->d_name[0] != '.') names.insert(e->d_name);
        closedir(d);
    }
    return names;
}

std::string tempDir() {
    char pattern[] = "/tmp/crumb-tests-XXXXXX";
    const char* dir = mkdtemp(pattern);
    return dir ? std::string(dir) + "/history" : "";
}

void removeDir(const std::string& dir) {
    for (const auto& name : listDir(dir)) unlink((dir + "/" + name).c_str());
    rmdir(dir.c_str());
    rmdir(dir.substr(0, dir.rfind('/')).c_str());
}

// Writes a text entry the way the app does: files first, then the index.
crumb::Item addText(crumb::Store& store, const std::string& text) {
    crumb::Item item;
    item.id = store.newId();
    item.kind = crumb::Kind::Text;
    item.flags = crumb::kHasText;
    item.bytes = text.size();
    item.fingerprint = crumb::fingerprint(text.data(), text.size());
    item.head = std::string(crumb::utf8Prefix(text, crumb::Store::kHeadBytes));
    crumb::writeFile(store.file(item.id, "txt"), text.data(), text.size());
    store.add(item);
    return item;
}

void testUtf8() {
    CHECK(crumb::decodeUtf8("abc") == U"abc");
    CHECK(crumb::decodeUtf8("h\xC3\xA9llo") == U"héllo");
    CHECK(crumb::decodeUtf8("\xF0\x9F\x8D\x9E") == U"🍞");
    CHECK(crumb::decodeUtf8("a\xFFz") == U"a�z");             // invalid byte
    CHECK(crumb::decodeUtf8("a\xE2\x82") == U"a��");     // truncated sequence
    CHECK(crumb::decodeUtf8("\xC0\xAF") == U"��");        // overlong
    CHECK(crumb::decodeUtf8("\xED\xA0\x80") == U"���");  // UTF-16 surrogate
    CHECK(crumb::decodeUtf8("abcdef", 3) == U"abc");
    CHECK(utf8(U"Crumb 🍞 é ж") == "Crumb 🍞 é ж");
    CHECK(crumb::utf8Prefix("héllo", 2) == "h");  // never splits é
    CHECK(crumb::utf8Prefix("héllo", 3) == "hé");
    CHECK(crumb::utf8Prefix("abc", 10) == "abc");
    CHECK(crumb::fold(U'A') == U'a');
    CHECK(crumb::fold(U'É') == U'e');
    CHECK(crumb::fold(U'ß') == U's');
    CHECK(crumb::fold(U'Ж') == U'ж');
    CHECK(crumb::fold(U'Ω') == U'ω');
    CHECK(crumb::fold(U'×') == U'×');
    CHECK(crumb::fold(U'7') == U'7');
}

void testLine() {
    auto plain = [](std::u32string_view s) { return crumb::makeLine(s, {}).text; };
    CHECK(plain(U"one\ntwo") == "one⏎two");
    CHECK(plain(U"one\r\ntwo") == "one⏎two");
    CHECK(plain(U"a\tb") == "a⇥b");
    CHECK(plain(U"  padded  ") == "··padded··");
    CHECK(plain(U"in side") == "in side");
    CHECK(plain(U"   ") == "···");
    CHECK(plain(U"bell\a") == "bell");
    CHECK(crumb::makeLine(U"abcdef", {}, 3).text == "abc");

    // Bold ranges are UTF-16 offsets: the emoji takes two units.
    const auto line = crumb::makeLine(U"🍞 bread", {2, 3});
    CHECK(line.text == "🍞 bread");
    CHECK(line.bold.size() == 1);
    CHECK(line.bold[0].first == 3 && line.bold[0].second == 2);

    // A match on \r\n lands on its ⏎.
    const auto crlf = crumb::makeLine(U"a\r\nb", {1});
    CHECK(crlf.text == "a⏎b");
    CHECK(crlf.bold.size() == 1 && crlf.bold[0].first == 1);

    // A far-away match is brought into view after an ellipsis.
    std::u32string longText(100, U'x');
    longText += U"needle";
    const auto far = crumb::makeLine(longText, {100, 101});
    CHECK(far.text.rfind("…", 0) == 0);
    CHECK(far.text.find("needle") != std::string::npos);
    CHECK(far.bold.size() == 1 && far.bold[0].first == 13);
}

bool matches(const char* query, const char32_t* text, int* score = nullptr, std::vector<uint32_t>* positions = nullptr) {
    const crumb::Query q(query);
    const auto h = crumb::prepare(text);
    int s = 0;
    std::vector<uint32_t> p;
    const bool ok = q.match(h, s, p);
    if (score) *score = s;
    if (positions) *positions = p;
    return ok;
}

void testFuzzy() {
    CHECK(crumb::Query("").empty());
    CHECK(crumb::Query("   ").empty());
    CHECK(matches("gp", U"git push"));
    CHECK(matches("GITPUSH", U"git push origin"));
    CHECK(matches("cafe", U"Café au lait"));
    CHECK(!matches("xyz", U"git push"));
    CHECK(!matches("pg", U"git push"));  // order matters
    CHECK(matches("push git", U"git push"));  // terms can come in any order
    CHECK(!matches("push zzz", U"git push"));

    std::vector<uint32_t> positions;
    CHECK(matches("gp", U"git push", nullptr, &positions));
    CHECK((positions == std::vector<uint32_t>{0, 4}));

    // Letters scattered across a long text are not a match.
    std::u32string scattered = U"a";
    scattered += std::u32string(100, U'-');
    scattered += U"b";
    CHECK(!matches("ab", scattered.c_str()));

    // Consecutive and word-start matches beat scattered ones; earlier beats later.
    int tight = 0, loose = 0, early = 0, late = 0;
    matches("crumb", U"crumb.txt", &tight);
    matches("crumb", U"cream rumba b", &loose);
    CHECK(tight > loose);
    matches("main", U"main.cpp and more", &early);
    matches("main", U"some text before the main.cpp", &late);
    CHECK(early > late);
    int boundary = 0, inner = 0;
    matches("rd", U"read data", &boundary);
    matches("rd", U"herdsman", &inner);
    CHECK(boundary > inner);
}

void testStore() {
    const std::string dir = tempDir();
    CHECK(!dir.empty());
    {
        crumb::Store store(dir);
        store.load();
        CHECK(store.items().empty());
        addText(store, "first");
        addText(store, "second");
        addText(store, "third");
        CHECK(store.items().size() == 3);
        CHECK(store.items()[0].head == "third");

        // Copying something again moves it to the top instead of duplicating it.
        const auto again = addText(store, "first");
        CHECK(store.items().size() == 3);
        CHECK(store.items()[0].head == "first");
        CHECK(store.items()[0].id == again.id);

        store.moveToTop(2);
        CHECK(store.items()[0].head == "second");
        store.remove(0);
        CHECK(store.items().size() == 2);
        CHECK(store.items()[0].head == "first");
    }
    {
        // Everything survives a restart, in order.
        crumb::Store store(dir);
        store.load();
        CHECK(store.items().size() == 2);
        CHECK(store.items()[0].head == "first");
        CHECK(store.items()[1].head == "third");
        CHECK(store.items()[0].flags == crumb::kHasText);
        CHECK(crumb::readFile(store.file(store.items()[0].id, "txt")) == "first");

        // New ids never reuse old ones.
        const auto item = addText(store, "fourth");
        CHECK(item.id > store.items()[1].id && item.id > store.items()[2].id);

        // The limit trims the oldest entries and their files.
        store.setLimit(2);
        CHECK(store.items().size() == 2);
        CHECK(store.items()[1].head == "first");
        CHECK(listDir(dir).count(std::to_string(store.items()[0].id) + ".txt") == 1);
        CHECK(listDir(dir).size() == 3);  // index + two texts

        // Big texts are stored in full; only the head stays in memory.
        const std::string big(3 << 20, 'z');
        addText(store, big);
        CHECK(store.items()[0].head.size() == crumb::Store::kHeadBytes);
        CHECK(store.items()[0].bytes == big.size());
        CHECK(crumb::readFile(store.file(store.items()[0].id, "txt")) == big);
    }
    {
        // Entries whose files vanished are dropped; stray files are deleted.
        crumb::Store store(dir);
        store.load();
        const auto victim = store.items()[1].id;
        unlink(store.file(victim, "txt").c_str());
        crumb::writeFile(dir + "/999.txt", "stray", 5);
        crumb::writeFile(dir + "/index.tmp", "x", 1);
        store.load();
        CHECK(store.items().size() == 1);
        CHECK(listDir(dir).count("999.txt") == 0);
        CHECK(listDir(dir).count("index.tmp") == 0);
        CHECK(store.newId() > 999);

        store.clear();
        CHECK(store.items().empty());
        CHECK(listDir(dir) == std::set<std::string>{"index"});
    }
    {
        crumb::Store store(dir);
        store.load();
        CHECK(store.items().empty());
        struct stat st {};
        CHECK(stat(dir.c_str(), &st) == 0 && (st.st_mode & 0777) == 0700);
        CHECK(stat((dir + "/index").c_str(), &st) == 0 && (st.st_mode & 0777) == 0600);
    }
    removeDir(dir);
}

void testStoreRecovery() {
    const std::string dir = tempDir();
    {
        // A history larger than the default limit survives a restart when the limit is set first.
        crumb::Store store(dir);
        store.setLimit(500);
        store.load();
        for (int i = 0; i < 150; ++i) addText(store, "entry " + std::to_string(i));
        crumb::Store again(dir);
        again.setLimit(500);
        again.load();
        CHECK(again.items().size() == 150);
        again.clear();
    }
    {
        crumb::Store store(dir);
        store.load();
        addText(store, "oldest");
        // A picture: just enough of a PNG header for its size to be read back.
        std::string png("\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR\0\0\x07\x80\0\0\x04\x38", 24);
        png += std::string(100, '\0');
        crumb::Item picture;
        picture.id = store.newId();
        picture.kind = crumb::Kind::Image;
        picture.flags = crumb::kHasImage;
        picture.bytes = png.size();
        picture.width = 1920;
        picture.height = 1080;
        picture.fingerprint = crumb::fingerprint(png.data(), png.size());
        crumb::writeFile(store.file(picture.id, "png"), png.data(), png.size());
        store.add(picture);
        const std::string paths = "/tmp/a.txt\n/tmp/b.txt";
        crumb::Item files;
        files.id = store.newId();
        files.kind = crumb::Kind::Files;
        files.bytes = paths.size();
        files.fingerprint = crumb::fingerprint(paths.data(), paths.size());
        files.head = paths;
        crumb::writeFile(store.file(files.id, "files"), paths.data(), paths.size());
        store.add(files);
        addText(store, "newest");
        CHECK(store.items().size() == 4);
    }
    for (const char* damage : {"missing", "empty", "garbage"}) {
        // Without a readable index nothing is lost: the history comes back from the files, newest first.
        if (std::string(damage) == "missing")
            unlink((dir + "/index").c_str());
        else
            crumb::writeFile(dir + "/index", std::string(damage) == "empty" ? "" : "nonsense\n1 2 3", std::string(damage) == "empty" ? 0 : 15);
        crumb::Store store(dir);
        store.load();
        CHECK(store.items().size() == 4);
        if (store.items().size() != 4) continue;
        CHECK(store.items()[0].head == "newest");
        CHECK(store.items()[1].kind == crumb::Kind::Files && store.items()[1].head == "/tmp/a.txt\n/tmp/b.txt");
        CHECK(store.items()[2].kind == crumb::Kind::Image && store.items()[2].width == 1920 && store.items()[2].height == 1080);
        CHECK(store.items()[3].head == "oldest" && store.items()[3].kind == crumb::Kind::Text);
        // Fingerprints are rebuilt, so copying the same text again still folds into one entry.
        CHECK(store.items()[3].fingerprint == crumb::fingerprint("oldest", 6));
    }
    {
        // Heads end on a character boundary even when the cut falls inside one.
        crumb::Store store(dir);
        store.load();
        const std::string text = std::string(crumb::Store::kHeadBytes - 1, 'a') + "é and more";
        addText(store, text);
        crumb::Store again(dir);
        again.load();
        CHECK(again.items()[0].head == std::string(crumb::Store::kHeadBytes - 1, 'a'));
        CHECK(crumb::readFile(again.file(again.items()[0].id, "txt")) == text);

        // An entry can go below the top (a copy that finished saving after a newer one).
        crumb::Item late;
        late.id = again.newId();
        late.kind = crumb::Kind::Text;
        late.flags = crumb::kHasText;
        late.head = "late";
        late.bytes = 4;
        late.fingerprint = crumb::fingerprint("late", 4);
        crumb::writeFile(again.file(late.id, "txt"), "late", 4);
        again.add(late, 1);
        CHECK(again.items()[1].head == "late");
        again.clear();
    }
    removeDir(dir);
}

void testVersion() {
    CHECK(crumb::isNewerVersion("1.0.1", "1.0.0"));
    CHECK(crumb::isNewerVersion("v1.10.0", "1.9.9"));
    CHECK(crumb::isNewerVersion("2", "1.9"));
    CHECK(!crumb::isNewerVersion("1.0.0", "1.0.0"));
    CHECK(!crumb::isNewerVersion("v1.0", "1.0.0"));
    CHECK(!crumb::isNewerVersion("0.9.9", "1.0.0"));
    CHECK(!crumb::isNewerVersion("", "1.0.0"));
}

}  // namespace

int main() {
    testUtf8();
    testLine();
    testFuzzy();
    testStore();
    testStoreRecovery();
    testVersion();
    std::printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
