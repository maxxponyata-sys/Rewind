#import "RWCore.h"

NSString *const RWLibraryDidChangeNotification = @"RWLibraryDidChangeNotification";

#define RWDefaults [NSUserDefaults standardUserDefaults]

@implementation RWSettings

+ (NSString *)defaultInstance { return @"https://yt.chocolatemoo53.com"; }

+ (NSString *)instance {
    NSString *s = [RWDefaults stringForKey:@"instance"];
    return s.length ? s : [self defaultInstance];
}

+ (void)setInstance:(NSString *)instance {
    NSString *s = [instance stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    if (s.length && [s rangeOfString:@"://"].location == NSNotFound) s = [@"https://" stringByAppendingString:s];
    if (s.length) [RWDefaults setObject:s forKey:@"instance"];
    else [RWDefaults removeObjectForKey:@"instance"];
}

+ (NSString *)region {
    NSString *r = [RWDefaults stringForKey:@"region"];
    if (r.length == 2) return r.uppercaseString;
    NSString *locale = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return locale.length == 2 ? locale.uppercaseString : @"US";
}

+ (void)setRegion:(NSString *)region {
    NSString *r = [region stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (r.length == 2) [RWDefaults setObject:r.uppercaseString forKey:@"region"];
    else [RWDefaults removeObjectForKey:@"region"];
}

+ (NSInteger)maxQuality {
    NSInteger q = [RWDefaults integerForKey:@"maxQuality"];
    return q > 0 ? q : 720;
}

+ (void)setMaxQuality:(NSInteger)quality { [RWDefaults setInteger:quality forKey:@"maxQuality"]; }
+ (BOOL)audioOnly { return [RWDefaults boolForKey:@"audioOnly"]; }
+ (void)setAudioOnly:(BOOL)audioOnly { [RWDefaults setBool:audioOnly forKey:@"audioOnly"]; }

@end

static NSArray *RWLoad(NSString *key) {
    NSArray *a = [RWDefaults arrayForKey:key];
    return a ?: @[];
}

static void RWStore(NSString *key, NSArray *list) {
    [RWDefaults setObject:list forKey:key];
    [[NSNotificationCenter defaultCenter] postNotificationName:RWLibraryDidChangeNotification object:nil];
}

static NSArray *RWWithout(NSArray *list, NSString *idKey, NSString *value) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in list) if (![d[idKey] isEqual:value]) [out addObject:d];
    return out;
}

static NSArray *RWVideos(NSArray *list) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in list) { RWVideo *v = [RWVideo videoWithDictionary:d]; if (v) [out addObject:v]; }
    return out;
}

@implementation RWLibrary

+ (NSArray<RWVideo *> *)saved { return RWVideos(RWLoad(@"saved")); }

+ (BOOL)isSaved:(NSString *)videoId {
    for (NSDictionary *d in RWLoad(@"saved")) if ([d[@"videoId"] isEqual:videoId]) return YES;
    return NO;
}

+ (void)toggleSaved:(RWVideo *)video {
    if (!video.videoId) return;
    if ([self isSaved:video.videoId]) { [self removeSaved:video.videoId]; return; }
    NSMutableArray *list = [RWLoad(@"saved") mutableCopy];
    [list insertObject:[video dictionaryRepresentation] atIndex:0];
    RWStore(@"saved", list);
}

+ (void)removeSaved:(NSString *)videoId { RWStore(@"saved", RWWithout(RWLoad(@"saved"), @"videoId", videoId)); }

+ (NSArray<RWVideo *> *)history { return RWVideos(RWLoad(@"history")); }

+ (void)addHistory:(RWVideo *)video {
    if (!video.videoId) return;
    NSMutableArray *list = [RWWithout(RWLoad(@"history"), @"videoId", video.videoId) mutableCopy];
    [list insertObject:[video dictionaryRepresentation] atIndex:0];
    while (list.count > 300) [list removeLastObject];
    RWStore(@"history", list);
}

+ (void)removeHistory:(NSString *)videoId { RWStore(@"history", RWWithout(RWLoad(@"history"), @"videoId", videoId)); }
+ (void)clearHistory { RWStore(@"history", @[]); }

+ (NSArray<RWChannel *> *)subscriptions {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in RWLoad(@"subscriptions")) { RWChannel *c = [RWChannel channelWithDictionary:d]; if (c) [out addObject:c]; }
    return out;
}

+ (BOOL)isSubscribed:(NSString *)ucid {
    for (NSDictionary *d in RWLoad(@"subscriptions")) if ([d[@"authorId"] isEqual:ucid]) return YES;
    return NO;
}

+ (void)toggleSubscription:(RWChannel *)channel {
    if (!channel.ucid) return;
    if ([self isSubscribed:channel.ucid]) { [self removeSubscription:channel.ucid]; return; }
    NSMutableArray *list = [RWLoad(@"subscriptions") mutableCopy];
    [list addObject:[channel dictionaryRepresentation]];
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [[a[@"author"] description] localizedCaseInsensitiveCompare:[b[@"author"] description]];
    }];
    RWStore(@"subscriptions", list);
}

+ (void)removeSubscription:(NSString *)ucid {
    RWStore(@"subscriptions", RWWithout(RWLoad(@"subscriptions"), @"authorId", ucid));
}

@end
