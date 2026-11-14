#import "RWCore.h"
#import <Security/Security.h>

UIColor *RWTintColor(void) {
    return [UIColor colorWithRed:0.89 green:0.12 blue:0.10 alpha:1.0];
}

NSURL *RWResolveURL(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return nil;
    if ([s hasPrefix:@"//"]) s = [@"https:" stringByAppendingString:s];
    else if ([s hasPrefix:@"/"]) s = [[RWSettings instance] stringByAppendingString:s];
    return [NSURL URLWithString:s];
}

NSString *RWCompactNumber(long long n) {
    double v = (double)n; NSString *suffix = @"";
    if (n >= 1000000000LL) { v /= 1e9; suffix = @"B"; }
    else if (n >= 1000000LL) { v /= 1e6; suffix = @"M"; }
    else if (n >= 1000LL) { v /= 1e3; suffix = @"K"; }
    else return [NSString stringWithFormat:@"%lld", n];
    NSString *num = v < 10 ? [NSString stringWithFormat:@"%.1f", v] : [NSString stringWithFormat:@"%.0f", v];
    if ([num hasSuffix:@".0"]) num = [num substringToIndex:num.length - 2];
    return [num stringByAppendingString:suffix];
}

static NSString *RWUserAgent(void) {
    return [NSString stringWithFormat:@"Rewind/%@ (iOS %@)", RW_VERSION, [UIDevice currentDevice].systemVersion];
}

static NSArray *RWAnchors(void) {
    static NSArray *anchors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        for (NSString *name in @[@"isrgrootx1", @"isrgrootx2"]) {
            NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"der"];
            NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
            if (!data) continue;
            SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);
            if (cert) [list addObject:(__bridge_transfer id)cert];
        }
        anchors = list;
    });
    return anchors;
}

static BOOL RWTrustPasses(SecTrustRef trust) {
    SecTrustResultType result = kSecTrustResultInvalid;
    if (SecTrustEvaluate(trust, &result) != errSecSuccess) return NO;
    return result == kSecTrustResultUnspecified || result == kSecTrustResultProceed;
}

@implementation RWNetwork {
    NSURLSession *_session;
    NSCache *_images;
}

+ (instancetype)shared {
    static RWNetwork *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 25;
        cfg.HTTPAdditionalHeaders = @{@"User-Agent": RWUserAgent()};
        [NSURLCache setSharedURLCache:[[NSURLCache alloc] initWithMemoryCapacity:8 * 1024 * 1024
                                                                    diskCapacity:64 * 1024 * 1024
                                                                        diskPath:@"rewind-cache"]];
        cfg.URLCache = [NSURLCache sharedURLCache];   // Settings → Clear image cache empties this
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
        _images = [NSCache new];
        _images.countLimit = 400;
    }
    return self;
}

+ (void)handleChallenge:(NSURLAuthenticationChallenge *)challenge
             completion:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    if (![challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    BOOL ok = RWTrustPasses(trust);
    if (!ok && RWAnchors().count) {
        SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)RWAnchors());
        SecTrustSetAnchorCertificatesOnly(trust, false);   // keep the system roots too
        ok = RWTrustPasses(trust);
    }
    if (ok) completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    else completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    [RWNetwork handleChallenge:challenge completion:completionHandler];
}

- (NSURLSessionDataTask *)getJSON:(NSURL *)url completion:(void (^)(id, NSError *))completion {
    if (!url) {
        completion(nil, [NSError errorWithDomain:@"Rewind" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid server address."}]);
        return nil;
    }
    NSURLSessionDataTask *task = [_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = nil;
        NSInteger code = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (!error && data) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            NSString *serverMessage = nil;
            if ([json isKindOfClass:[NSDictionary class]] && [((NSDictionary *)json)[@"error"] isKindOfClass:[NSString class]])
                serverMessage = ((NSDictionary *)json)[@"error"];
            if (code >= 400 || serverMessage || !json) {
                NSString *msg = serverMessage;
                if (!msg && code == 403) msg = @"The server refused the request (HTTP 403). Many public servers block apps — try another server in Settings.";
                if (!msg && code >= 400) msg = [NSString stringWithFormat:@"The server returned HTTP %ld.", (long)code];
                if (!msg) msg = @"The server sent a response Rewind couldn't read. Is this an Invidious server?";
                error = [NSError errorWithDomain:@"Rewind" code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
                json = nil;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json, error); });
    }];
    [task resume];
    return task;
}

- (void)fetchURL:(NSURL *)url range:(NSString *)range
      completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    if (range.length) [request setValue:range forHTTPHeaderField:@"Range"];
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        completion(data, [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil, error);
    }] resume];
}

// Invidious answers stream URLs with a redirect to its proxy; keep the Range header across it.
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSString *range = [task.originalRequest valueForHTTPHeaderField:@"Range"];
    if (!range) { completionHandler(request); return; }
    NSMutableURLRequest *next = [request mutableCopy];
    [next setValue:range forHTTPHeaderField:@"Range"];
    completionHandler(next);
}

- (void)loadImage:(NSURL *)url completion:(void (^)(UIImage *))completion {
    if (!url) { completion(nil); return; }
    UIImage *cached = [_images objectForKey:url];
    if (cached) { completion(cached); return; }
    NSCache *images = _images;
    [[_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        if (image) [images setObject:image forKey:url];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
    }] resume];
}

@end

#pragma mark - Stream loader

static NSString *const RWSchemePrefix = @"rw";

@interface RWResourceLoader () <NSURLSessionDataDelegate>
@end

@implementation RWResourceLoader {
    dispatch_queue_t _queue;
    NSURLSession *_session;
    NSMutableDictionary<NSNumber *, AVAssetResourceLoadingRequest *> *_requests;
    NSMutableDictionary<NSNumber *, NSURLSessionTask *> *_tasks;
    NSMutableDictionary<NSNumber *, NSNumber *> *_skip;   // bytes to drop when a server ignores Range
}

+ (instancetype)shared {
    static RWResourceLoader *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("rewind.stream-loader", DISPATCH_QUEUE_SERIAL);
        NSOperationQueue *opQueue = [NSOperationQueue new];
        opQueue.maxConcurrentOperationCount = 1;
        opQueue.underlyingQueue = _queue;
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.HTTPAdditionalHeaders = @{@"User-Agent": RWUserAgent()};
        cfg.URLCache = nil;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.HTTPMaximumConnectionsPerHost = 6;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:opQueue];
        _requests = [NSMutableDictionary dictionary];
        _tasks = [NSMutableDictionary dictionary];
        _skip = [NSMutableDictionary dictionary];
    }
    return self;
}

- (AVURLAsset *)assetWithURL:(NSURL *)url {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.scheme = [RWSchemePrefix stringByAppendingString:c.scheme ?: @"https"];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:c.URL options:nil];
    [asset.resourceLoader setDelegate:self queue:_queue];
    return asset;
}

- (void)forgetTask:(NSURLSessionTask *)task {
    NSNumber *key = @(task.taskIdentifier);
    [_requests removeObjectForKey:key];
    [_tasks removeObjectForKey:key];
    [_skip removeObjectForKey:key];
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURLComponents *c = [NSURLComponents componentsWithURL:loadingRequest.request.URL resolvingAgainstBaseURL:NO];
    if (![c.scheme hasPrefix:RWSchemePrefix]) return NO;
    c.scheme = [c.scheme substringFromIndex:RWSchemePrefix.length];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:c.URL];
    request.timeoutInterval = 30;
    AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
    long long start = 0;
    NSString *range = @"bytes=0-1";
    if (dataRequest) {
        start = dataRequest.requestedOffset;
        if (dataRequest.requestsAllDataToEndOfResource || dataRequest.requestedLength <= 0)
            range = [NSString stringWithFormat:@"bytes=%lld-", start];
        else
            range = [NSString stringWithFormat:@"bytes=%lld-%lld", start, start + (long long)dataRequest.requestedLength - 1];
    }
    [request setValue:range forHTTPHeaderField:@"Range"];

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request];
    NSNumber *key = @(task.taskIdentifier);
    _requests[key] = loadingRequest;
    _tasks[key] = task;
    _skip[key] = @(start);
    [task resume];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    for (NSNumber *key in _requests.allKeys) {
        if (_requests[key] == loadingRequest) {
            NSURLSessionTask *task = _tasks[key];
            [self forgetTask:task];
            [task cancel];
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSMutableURLRequest *next = [request mutableCopy];
    NSString *range = [task.originalRequest valueForHTTPHeaderField:@"Range"];
    if (range) [next setValue:range forHTTPHeaderField:@"Range"];
    completionHandler(next);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSNumber *key = @(dataTask.taskIdentifier);
    AVAssetResourceLoadingRequest *loadingRequest = _requests[key];
    if (!loadingRequest || loadingRequest.isCancelled || loadingRequest.isFinished) {
        [self forgetTask:dataTask];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger code = http ? http.statusCode : 200;
    if (code >= 400) {
        NSString *msg = [NSString stringWithFormat:@"The video server returned HTTP %ld.", (long)code];
        [loadingRequest finishLoadingWithError:[NSError errorWithDomain:@"Rewind" code:code userInfo:@{NSLocalizedDescriptionKey: msg}]];
        [self forgetTask:dataTask];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (code == 206) _skip[key] = @0;   // server honoured Range; otherwise drop leading bytes ourselves

    long long total = response.expectedContentLength;
    for (NSString *header in http.allHeaderFields) {
        if ([header caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) {
            NSString *value = http.allHeaderFields[header];
            NSRange slash = [value rangeOfString:@"/" options:NSBackwardsSearch];
            if (slash.location != NSNotFound) total = [[value substringFromIndex:slash.location + 1] longLongValue];
        }
    }
    AVAssetResourceLoadingContentInformationRequest *info = loadingRequest.contentInformationRequest;
    if (info) {
        NSString *mime = response.MIMEType.lowercaseString ?: @"";
        info.contentType = [mime hasPrefix:@"audio"] ? @"public.mpeg-4-audio" : @"public.mpeg-4";
        info.contentLength = total;
        info.byteRangeAccessSupported = YES;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    NSNumber *key = @(dataTask.taskIdentifier);
    AVAssetResourceLoadingRequest *loadingRequest = _requests[key];
    if (!loadingRequest || loadingRequest.isCancelled || loadingRequest.isFinished) return;
    long long skip = [_skip[key] longLongValue];
    if (skip > 0) {
        if ((long long)data.length <= skip) { _skip[key] = @(skip - (long long)data.length); return; }
        data = [data subdataWithRange:NSMakeRange((NSUInteger)skip, data.length - (NSUInteger)skip)];
        _skip[key] = @0;
    }
    [loadingRequest.dataRequest respondWithData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    AVAssetResourceLoadingRequest *loadingRequest = _requests[@(task.taskIdentifier)];
    [self forgetTask:task];
    if (!loadingRequest || loadingRequest.isCancelled || loadingRequest.isFinished) return;
    if (error) [loadingRequest finishLoadingWithError:error];
    else [loadingRequest finishLoading];
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    [RWNetwork handleChallenge:challenge completion:completionHandler];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    [RWNetwork handleChallenge:challenge completion:completionHandler];
}

@end
