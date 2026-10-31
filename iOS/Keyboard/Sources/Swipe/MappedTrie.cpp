#include "MappedTrie.hpp"

#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

struct MappedTrieVTable {
    static const MappedTrie::Node& node(void* self, TrieId id) {
        return static_cast<MappedTrie*>(self)->nodes_[id];
    }
    static int num_chars(void*) { return 26; }
    static TrieId root(void*) { return 0; }
    static int char_idx(void* self, TrieId id) {
        uint8_t letter = node(self, id).letter;
        return letter == 255 ? -1 : letter;
    }
    static uint32_t child_count(void* self, TrieId id) { return node(self, id).child_count; }
    static TrieId child(void* self, TrieId id, uint32_t i) { return node(self, id).first_child + i; }
    static bool is_word(void* self, TrieId id) { return node(self, id).word_offset != UINT32_MAX; }
    // FUTO's own trie returns -100 for a node that is not a word.
    static float log_frequency(void* self, TrieId id) {
        const auto& n = node(self, id);
        return n.word_offset == UINT32_MAX ? -100.0f : n.frequency;
    }
    static uint16_t depth(void* self, TrieId id) { return node(self, id).depth; }
    static const char* word(void* self, TrieId id) {
        const auto& n = node(self, id);
        return n.word_offset == UINT32_MAX ? nullptr : static_cast<MappedTrie*>(self)->blob_ + n.word_offset;
    }
    static void end_search(void*) {}

    static constexpr ITrieVTable table = {
        &num_chars, &root, &char_idx, &child_count, &child,
        &is_word, &log_frequency, &depth, &word, &end_search,
    };
};

MappedTrie::MappedTrie(const std::string& path) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > 16) {
        void* map = mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (map != MAP_FAILED) {
            map_ = map;
            size_ = st.st_size;
        }
    }
    close(fd);
    if (!map_) return;
    const char* bytes = static_cast<const char*>(map_);
    uint32_t header[3];
    std::memcpy(header, bytes + 4, sizeof header);
    size_t nodes_end = 16 + size_t(header[1]) * sizeof(Node);
    if (std::memcmp(bytes, "VQST", 4) != 0 || header[0] != 1 || nodes_end + header[2] > size_) return;
    nodes_ = reinterpret_cast<const Node*>(bytes + 16);
    count_ = header[1];
    blob_ = bytes + nodes_end;
    itrie_.userdata = this;
    itrie_.vtable = &MappedTrieVTable::table;
}

MappedTrie::~MappedTrie() {
    if (map_) munmap(map_, size_);
}
