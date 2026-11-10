#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// All callbacks run on the private engine queue. Payloads are immutable JSON.
@interface ButterEngine : NSObject
- (instancetype)initWithStorage:(NSString *)storage;
- (void)perform:(NSString *)command payload:(NSData *)payload completion:(void (^)(NSData * _Nullable, NSString * _Nullable))completion;
- (void)snapshot:(void (^)(NSData * _Nullable, NSString * _Nullable))completion;
@property(nonatomic, readonly) double creationProgress;
- (void)cancelCreation;
@end
NS_ASSUME_NONNULL_END
