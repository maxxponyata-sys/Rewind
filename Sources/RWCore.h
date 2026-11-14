// Rewind — a YouTube client for iOS 10, powered by Invidious.
// Core: settings, networking, models, API, local library, stream loader.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#define RW_VERSION @"1.0.0"
#define RW_SOURCE_URL @"https://github.com/maxxponyata-sys/Rewind"

extern NSString *const RWLibraryDidChangeNotification;

UIColor *RWTintColor(void);
NSURL *RWResolveURL(NSString *pathOrURL);
NSString *RWCompactNumber(long long n);

#pragma mark - Settings

@interface RWSettings : NSObject
+ (NSString *)defaultInstance;
+ (NSString *)instance;                 // "https://host", no trailing slash
+ (void)setInstance:(NSString *)instance;
+ (NSString *)region;                   // two-letter country code
+ (void)setRegion:(NSString *)region;
+ (NSInteger)maxQuality;                // 240 / 360 / 480 / 720 / 1080
+ (void)setMaxQuality:(NSInteger)quality;
+ (BOOL)audioOnly;
+ (void)setAudioOnly:(BOOL)audioOnly;
@end

#pragma mark - Networking

@interface RWNetwork : NSObject <NSURLSessionDelegate>
+ (instancetype)shared;
- (NSURLSessionDataTask *)getJSON:(NSURL *)url completion:(void (^)(id json, NSError *error))completion;
- (void)loadImage:(NSURL *)url completion:(void (^)(UIImage *image))completion;
// Trusts the system roots plus the bundled ISRG roots (iOS 10 predates ISRG Root X1).
+ (void)handleChallenge:(NSURLAuthenticationChallenge *)challenge
             completion:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completion;
@end

#pragma mark - Models

@interface RWVideo : NSObject
@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *authorId;
@property (nonatomic, copy) NSString *viewText;
@property (nonatomic, copy) NSString *publishedText;
@property (nonatomic) NSInteger lengthSeconds;
@property (nonatomic) NSTimeInterval published;
@property (nonatomic) BOOL live;
+ (instancetype)videoWithDictionary:(NSDictionary *)dict;   // API or stored form
- (NSDictionary *)dictionaryRepresentation;
- (NSURL *)thumbnailURL;
- (NSString *)durationText;
- (NSString *)metaText;
@end

@interface RWChannel : NSObject
@property (nonatomic, copy) NSString *ucid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *subText;
@property (nonatomic, copy) NSString *avatar;
+ (instancetype)channelWithDictionary:(NSDictionary *)dict;  // API or stored form
- (NSDictionary *)dictionaryRepresentation;
- (NSURL *)avatarURL;
@end

#pragma mark - API

typedef void (^RWItemsBlock)(NSArray *items, NSString *next, NSError *error);

@interface RWAPI : NSObject
+ (void)trending:(RWItemsBlock)completion;
+ (void)search:(NSString *)query type:(NSString *)type page:(NSInteger)page completion:(RWItemsBlock)completion;
+ (void)channelVideos:(NSString *)ucid continuation:(NSString *)continuation completion:(RWItemsBlock)completion;
+ (void)channel:(NSString *)ucid completion:(void (^)(NSDictionary *info, NSError *error))completion;
+ (void)video:(NSString *)videoId completion:(void (^)(NSDictionary *info, NSError *error))completion;
+ (void)subscriptionFeed:(RWItemsBlock)completion;
+ (void)stats:(void (^)(NSDictionary *info, NSError *error))completion;
@end

#pragma mark - Library (saved / history / subscriptions, stored locally)

@interface RWLibrary : NSObject
+ (NSArray<RWVideo *> *)saved;
+ (BOOL)isSaved:(NSString *)videoId;
+ (void)toggleSaved:(RWVideo *)video;
+ (void)removeSaved:(NSString *)videoId;

+ (NSArray<RWVideo *> *)history;
+ (void)addHistory:(RWVideo *)video;
+ (void)removeHistory:(NSString *)videoId;
+ (void)clearHistory;

+ (NSArray<RWChannel *> *)subscriptions;
+ (BOOL)isSubscribed:(NSString *)ucid;
+ (void)toggleSubscription:(RWChannel *)channel;
+ (void)removeSubscription:(NSString *)ucid;
@end

#pragma mark - Stream loader

// Feeds AVFoundation through our own NSURLSession so streams from servers with
// modern Let's Encrypt certificates play on iOS 10.
@interface RWResourceLoader : NSObject <AVAssetResourceLoaderDelegate>
+ (instancetype)shared;
- (AVURLAsset *)assetWithURL:(NSURL *)url;
@end
