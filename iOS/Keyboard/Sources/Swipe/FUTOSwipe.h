// FUTO Swipe (swipe-library, GPL-3.0) for Swift: recognizes a slide across
// the letters as words. Not thread-safe; SwipeRecognizer owns the queue.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FUTOSwipe : NSObject

/// Loads the encoder, the dictionary and the context model from `directory`
/// (Resources/swipe). `xs` and `ys` are the centres of the keys a to z, in
/// the space a gesture is given in: 0 to 1 across the letter keys.
/// `decoder` adds the QWERTY decoder, which knows only that layout.
- (nullable instancetype)initWithDirectory:(NSString *)directory
                                        xs:(NSArray<NSNumber *> *)xs
                                        ys:(NSArray<NSNumber *> *)ys
                                   decoder:(BOOL)decoder;

- (BOOL)setLayoutXs:(NSArray<NSNumber *> *)xs ys:(NSArray<NSNumber *> *)ys decoder:(BOOL)decoder;

/// The user's own words, as letters a to z, searched beside the dictionary.
- (void)setUserWords:(NSArray<NSString *> *)words;

/// Best words first. `t` is milliseconds since the first point; `context`
/// is the words before the cursor, oldest first.
- (NSArray<NSString *> *)recognizeX:(const float *)x
                                  y:(const float *)y
                                  t:(const float *)t
                              count:(NSInteger)count
                            context:(NSArray<NSString *> *)context;

@end

NS_ASSUME_NONNULL_END
