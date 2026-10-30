#import "FUTOSwipe.h"

#include "MappedTrie.hpp"
#include "swipe_decoder/engine.hpp"
#include "swipe_decoder/trie.hpp"

#include <memory>
#include <string>
#include <vector>

/// About as common as "see" (152): above a rarer word of the same shape.
static const float kUserWordFrequency = 150;
static NSString *const kLetters = @"abcdefghijklmnopqrstuvwxyz";

@implementation FUTOSwipe {
    NSString *_directory;
    std::unique_ptr<MappedTrie> _words;
    std::unique_ptr<swipe_decoder::Trie> _userWords;
    swipe_decoder::SwipeEngine _engine;
}

static swipe_decoder::KeyboardLayout Layout(NSArray<NSNumber *> *xs, NSArray<NSNumber *> *ys) {
    std::vector<float> cx, cy;
    for (NSNumber *x in xs) cx.push_back(x.floatValue);
    for (NSNumber *y in ys) cy.push_back(y.floatValue);
    return swipe_decoder::make_layout(kLetters.UTF8String, cx.data(), cy.data(), (int)cx.size());
}

- (std::string)path:(NSString *)file {
    return [_directory stringByAppendingPathComponent:file].fileSystemRepresentation;
}

- (nullable instancetype)initWithDirectory:(NSString *)directory
                                        xs:(NSArray<NSNumber *> *)xs
                                        ys:(NSArray<NSNumber *> *)ys
                                   decoder:(BOOL)decoder {
    if (!(self = [super init]) || xs.count != 26 || ys.count != 26) return nil;
    _directory = directory;
    _words = std::make_unique<MappedTrie>([self path:@"words.trie"]);
    if (!_words->ok()) return nil;
    swipe_decoder::SwipeEngine::Config config;
    config.encoder_path = [self path:@"honorable_sturgeon/model_fp32.pte"];
    config.decoder_path = decoder ? [self path:@"magic_macaw/model_fp32.pte"] : "";
    config.lm_model_path = [self path:@"hungry_jellyfish/context_lm.pte"];
    config.lm_vocab_path = [self path:@"hungry_jellyfish/vocab.txt"];
    config.layout = Layout(xs, ys);
    config.dictionaries = {_words->itrie()};
    config.top_k = 4;
    return _engine.init(config) ? self : nil;
}

- (BOOL)setLayoutXs:(NSArray<NSNumber *> *)xs ys:(NSArray<NSNumber *> *)ys decoder:(BOOL)decoder {
    if (xs.count != 26 || ys.count != 26) return NO;
    swipe_decoder::SwipeEngine::Mode mode;
    mode.layout = Layout(xs, ys);
    mode.decoder_path = decoder ? [self path:@"magic_macaw/model_fp32.pte"] : "";
    return _engine.setMode(mode);
}

- (void)setUserWords:(NSArray<NSString *> *)words {
    auto trie = std::make_unique<swipe_decoder::Trie>();
    for (NSString *word in words) trie->insert(word.UTF8String, kUserWordFrequency, true);
    swipe_decoder::SwipeEngine::Mode mode;
    mode.dictionaries = std::vector<ITrie *>{_words->itrie(), trie->itrie()};
    if (_engine.setMode(mode)) _userWords = std::move(trie);
}

- (NSArray<NSString *> *)recognizeX:(const float *)x
                                  y:(const float *)y
                                  t:(const float *)t
                              count:(NSInteger)count
                            context:(NSArray<NSString *> *)context {
    std::vector<std::string> words;
    for (NSString *word in context) words.emplace_back(word.UTF8String);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (const auto &result : _engine.recognize(x, y, t, (size_t)count, words)) {
        NSString *word = [NSString stringWithUTF8String:result.word.c_str()];
        if (word) [out addObject:word];
    }
    return out;
}

@end
