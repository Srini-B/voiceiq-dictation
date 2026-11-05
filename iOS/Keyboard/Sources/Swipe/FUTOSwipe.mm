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
    config.lm_model_path = [self path:@"chosen_planarian/context_lm.pte"];
    config.lm_vocab_path = [self path:@"chosen_planarian/vocab.txt"];
    // The library's built-in scoring predates chosen_planarian; without these
    // weights it falls back to the encoder's, which ignore the context model.
    config.scoring_path = [self path:@"scoring.json"];
    config.layout = Layout(xs, ys);
    config.dictionaries = {_words->itrie()};
    config.top_k = 4;
    if (!_engine.init(config)) return nil;
    // Right after loading, the scoring in use is the one for slides with context.
    if (_engine.scoring().alpha <= 0) NSLog(@"FUTO Swipe: no scoring for the context model; slides ignore the words before them");
    return self;
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

static std::vector<std::string> Words(NSArray<NSString *> *context) {
    std::vector<std::string> words;
    for (NSString *word in context) words.emplace_back(word.UTF8String);
    return words;
}

- (NSArray<NSString *> *)recognizeX:(const float *)x
                                  y:(const float *)y
                                  t:(const float *)t
                              count:(NSInteger)count
                            context:(NSArray<NSString *> *)context {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (const auto &result : _engine.recognize(x, y, t, (size_t)count, Words(context))) {
        NSString *word = [NSString stringWithUTF8String:result.word.c_str()];
        if (word) [out addObject:word];
    }
    return out;
}

- (NSData *)predictAfter:(NSArray<NSString *> *)context scores:(NSMutableData *)scores {
    auto ranked = _engine.predict_next(Words(context), INT_MAX);
    std::string words;
    scores.length = ranked.size() * sizeof(float);
    float *out = (float *)scores.mutableBytes;
    for (size_t i = 0; i < ranked.size(); ++i) {
        words += ranked[i].first;
        words += '\n';
        out[i] = ranked[i].second;
    }
    return [NSData dataWithBytes:words.data() length:words.size()];
}

@end
