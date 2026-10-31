// The swipe dictionary (scripts/generate-swipe-trie.py), memory-mapped and
// served to FUTO Swipe through its ITrie interface.
#pragma once

#include "swipe_decoder/itrie.h"
#include <cstddef>
#include <cstdint>
#include <string>

class MappedTrie {
public:
    explicit MappedTrie(const std::string& path);
    ~MappedTrie();
    MappedTrie(const MappedTrie&) = delete;
    MappedTrie& operator=(const MappedTrie&) = delete;

    bool ok() const { return nodes_ != nullptr; }
    ITrie* itrie() { return &itrie_; }

private:
#pragma pack(push, 1)
    struct Node {
        uint32_t first_child;
        uint32_t word_offset;
        uint8_t child_count;
        uint8_t letter;
        uint8_t depth;
        uint8_t frequency;
    };
#pragma pack(pop)
    static_assert(sizeof(Node) == 12, "matches generate-swipe-trie.py");

    void* map_ = nullptr;
    size_t size_ = 0;
    const Node* nodes_ = nullptr;
    uint32_t count_ = 0;
    const char* blob_ = nullptr;
    ITrie itrie_{};

    friend struct MappedTrieVTable;
};
