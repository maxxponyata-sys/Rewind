#import "RWCore.h"

static NSString *RWStr(id o) {
    if ([o isKindOfClass:[NSString class]]) return o;
    if ([o isKindOfClass:[NSNumber class]]) return [o stringValue];
    return nil;
}

static double RWNum(id o) {
    return ([o isKindOfClass:[NSNumber class]] || [o isKindOfClass:[NSString class]]) ? [o doubleValue] : 0;
}

#pragma mark - Models

@implementation RWVideo

+ (instancetype)videoWithDictionary:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]] || !RWStr(d[@"videoId"])) return nil;
    RWVideo *v = [RWVideo new];
    v.videoId = RWStr(d[@"videoId"]);
    v.title = RWStr(d[@"title"]) ?: @"";
    v.author = RWStr(d[@"author"]) ?: @"";
    v.authorId = RWStr(d[@"authorId"]);
    v.lengthSeconds = (NSInteger)RWNum(d[@"lengthSeconds"]);
    v.published = RWNum(d[@"published"]);
    v.publishedText = RWStr(d[@"publishedText"]);
    v.live = [d[@"liveNow"] isKindOfClass:[NSNumber class]] && [d[@"liveNow"] boolValue];
    if (RWStr(d[@"viewText"])) v.viewText = RWStr(d[@"viewText"]);
    else if (RWNum(d[@"viewCount"]) > 0) v.viewText = [NSString stringWithFormat:@"%@ views", RWCompactNumber((long long)RWNum(d[@"viewCount"]))];
    else if (RWStr(d[@"viewCountText"]).length) v.viewText = RWStr(d[@"viewCountText"]);
    return v;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"videoId"] = self.videoId;
    if (self.title) d[@"title"] = self.title;
    if (self.author) d[@"author"] = self.author;
    if (self.authorId) d[@"authorId"] = self.authorId;
    if (self.viewText) d[@"viewText"] = self.viewText;
    if (self.publishedText) d[@"publishedText"] = self.publishedText;
    d[@"lengthSeconds"] = @(self.lengthSeconds);
    d[@"published"] = @(self.published);
    return d;
}

- (NSURL *)thumbnailURL {
    return RWResolveURL([NSString stringWithFormat:@"/vi/%@/mqdefault.jpg", self.videoId]);
}

- (NSString *)durationText {
    if (self.live) return @"LIVE";
    NSInteger s = self.lengthSeconds;
    if (s <= 0) return nil;
    if (s >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(s / 3600), (long)(s / 60 % 60), (long)(s % 60)];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(s / 60), (long)(s % 60)];
}

- (NSString *)metaText {
    NSMutableArray *parts = [NSMutableArray array];
    if (self.author.length) [parts addObject:self.author];
    if (self.viewText.length) [parts addObject:self.viewText];
    if (self.publishedText.length) [parts addObject:self.publishedText];
    return [parts componentsJoinedByString:@" · "];
}

@end

@implementation RWChannel

+ (instancetype)channelWithDictionary:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]] || !RWStr(d[@"authorId"])) return nil;
    RWChannel *c = [RWChannel new];
    c.ucid = RWStr(d[@"authorId"]);
    c.name = RWStr(d[@"author"]) ?: @"";
    if (RWStr(d[@"subText"])) c.subText = RWStr(d[@"subText"]);
    else if (RWNum(d[@"subCount"]) > 0) c.subText = [NSString stringWithFormat:@"%@ subscribers", RWCompactNumber((long long)RWNum(d[@"subCount"]))];
    else if (RWStr(d[@"subCountText"]).length) c.subText = RWStr(d[@"subCountText"]);
    c.avatar = RWStr(d[@"avatar"]);
    NSArray *thumbs = d[@"authorThumbnails"];
    if (!c.avatar && [thumbs isKindOfClass:[NSArray class]]) {
        for (NSDictionary *t in thumbs) {
            if (![t isKindOfClass:[NSDictionary class]]) continue;
            c.avatar = RWStr(t[@"url"]);
            if (RWNum(t[@"width"]) >= 100) break;
        }
    }
    if ([c.avatar hasPrefix:@"//"]) c.avatar = [@"https:" stringByAppendingString:c.avatar];
    return c;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"authorId"] = self.ucid;
    if (self.name) d[@"author"] = self.name;
    if (self.subText) d[@"subText"] = self.subText;
    if (self.avatar) d[@"avatar"] = self.avatar;
    return d;
}

- (NSURL *)avatarURL { return RWResolveURL(self.avatar); }

@end

#pragma mark - API

static NSString *const RWListFields = @"type,videoId,title,author,authorId,lengthSeconds,viewCount,published,publishedText,liveNow,authorThumbnails,subCount";

static NSURL *RWAPIURL(NSString *path, NSDictionary *query) {
    NSURLComponents *c = [NSURLComponents componentsWithString:[[RWSettings instance] stringByAppendingString:path]];
    if (!c) return nil;
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *key in query) [items addObject:[NSURLQueryItem queryItemWithName:key value:[query[key] description]]];
    if (items.count) c.queryItems = items;
    if (c.percentEncodedQuery) c.percentEncodedQuery = [c.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    return c.URL;
}

static NSString *RWPathComponent(NSString *s) {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: @"";
}

static NSArray *RWParseItems(id json) {
    NSArray *list = nil;
    if ([json isKindOfClass:[NSArray class]]) list = json;
    else if ([json isKindOfClass:[NSDictionary class]] && [json[@"videos"] isKindOfClass:[NSArray class]]) list = json[@"videos"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in list) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *type = RWStr(d[@"type"]);
        if ([type isEqualToString:@"channel"]) {
            RWChannel *c = [RWChannel channelWithDictionary:d];
            if (c) [out addObject:c];
        } else if (!type || [type isEqualToString:@"video"] || [type isEqualToString:@"shortVideo"]) {
            RWVideo *v = [RWVideo videoWithDictionary:d];
            if (v) [out addObject:v];
        }
    }
    return out;
}

@implementation RWAPI

+ (void)trending:(RWItemsBlock)completion {
    NSDictionary *q = @{@"region": [RWSettings region], @"fields": RWListFields};
    [[RWNetwork shared] getJSON:RWAPIURL(@"/api/v1/trending", q) completion:^(id json, NSError *error) {
        NSArray *items = RWParseItems(json);
        if (items.count) { completion(items, nil, nil); return; }
        // Trending is unavailable on some servers; fall back to the server's popular list.
        [[RWNetwork shared] getJSON:RWAPIURL(@"/api/v1/popular", @{@"fields": RWListFields}) completion:^(id json2, NSError *error2) {
            NSArray *popular = RWParseItems(json2);
            completion(popular, nil, popular.count ? nil : (error ?: error2));
        }];
    }];
}

+ (void)search:(NSString *)query type:(NSString *)type page:(NSInteger)page completion:(RWItemsBlock)completion {
    NSDictionary *q = @{@"q": query ?: @"", @"type": type ?: @"video", @"page": @(MAX(page, 1)), @"fields": RWListFields};
    [[RWNetwork shared] getJSON:RWAPIURL(@"/api/v1/search", q) completion:^(id json, NSError *error) {
        NSArray *items = RWParseItems(json);
        completion(items, items.count ? [NSString stringWithFormat:@"%ld", (long)MAX(page, 1) + 1] : nil, error);
    }];
}

+ (void)channelVideos:(NSString *)ucid continuation:(NSString *)continuation completion:(RWItemsBlock)completion {
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    if (continuation.length) q[@"continuation"] = continuation;
    NSString *path = [NSString stringWithFormat:@"/api/v1/channels/%@/videos", RWPathComponent(ucid)];
    [[RWNetwork shared] getJSON:RWAPIURL(path, q) completion:^(id json, NSError *error) {
        NSArray *items = RWParseItems(json);
        NSString *next = [json isKindOfClass:[NSDictionary class]] ? RWStr(json[@"continuation"]) : nil;
        completion(items, next.length ? next : nil, error);
    }];
}

+ (void)channel:(NSString *)ucid completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *path = [NSString stringWithFormat:@"/api/v1/channels/%@", RWPathComponent(ucid)];
    NSDictionary *q = @{@"fields": @"author,authorId,authorThumbnails,subCount,description"};
    [[RWNetwork shared] getJSON:RWAPIURL(path, q) completion:^(id json, NSError *error) {
        completion([json isKindOfClass:[NSDictionary class]] ? json : nil, error);
    }];
}

+ (void)video:(NSString *)videoId completion:(void (^)(NSDictionary *, NSError *))completion {
    // local=true makes the server proxy the streams; googlevideo links are locked to the server's IP.
    NSString *path = [NSString stringWithFormat:@"/api/v1/videos/%@", RWPathComponent(videoId)];
    [[RWNetwork shared] getJSON:RWAPIURL(path, @{@"local": @"true"}) completion:^(id json, NSError *error) {
        completion([json isKindOfClass:[NSDictionary class]] ? json : nil, error);
    }];
}

+ (void)subscriptionFeed:(RWItemsBlock)completion {
    NSArray<RWChannel *> *subs = [RWLibrary subscriptions];
    if (!subs.count) { completion(@[], nil, nil); return; }
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray *all = [NSMutableArray array];
    __block NSError *lastError = nil;
    for (RWChannel *channel in subs) {
        dispatch_group_enter(group);
        [self channelVideos:channel.ucid continuation:nil completion:^(NSArray *items, NSString *next, NSError *error) {
            if (items.count) [all addObjectsFromArray:items];
            else if (error) lastError = error;
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSArray *sorted = [all sortedArrayUsingComparator:^NSComparisonResult(RWVideo *a, RWVideo *b) {
            if (a.published == b.published) return NSOrderedSame;
            return a.published > b.published ? NSOrderedAscending : NSOrderedDescending;
        }];
        if (sorted.count > 200) sorted = [sorted subarrayWithRange:NSMakeRange(0, 200)];
        completion(sorted, nil, sorted.count ? nil : lastError);
    });
}

+ (void)stats:(void (^)(NSDictionary *, NSError *))completion {
    [[RWNetwork shared] getJSON:RWAPIURL(@"/api/v1/stats", nil) completion:^(id json, NSError *error) {
        completion([json isKindOfClass:[NSDictionary class]] ? json : nil, error);
    }];
}

@end
