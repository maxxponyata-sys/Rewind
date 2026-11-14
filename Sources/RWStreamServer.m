// Local HLS server.
//
// YouTube serves picture and sound as separate fragmented MP4 files (DASH). Their
// headers carry no samples, so AVComposition sees empty tracks. iOS 10 does play
// fragmented MP4 through HLS though, so this file turns each DASH stream into an
// HLS media playlist (segments taken from the file's `sidx` index, addressed with
// EXT-X-BYTERANGE) and serves everything from 127.0.0.1. Media byte ranges are
// fetched from the Invidious server through RWNetwork, which trusts the bundled
// Let's Encrypt roots that iOS 10 lacks.

#import "RWCore.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>

static const uint16_t RWPreferredPort = 18970;

#pragma mark - DASH index → HLS playlist

static uint32_t RWBE32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static uint64_t RWBE64(const uint8_t *p) { return ((uint64_t)RWBE32(p) << 32) | RWBE32(p + 4); }

static BOOL RWParseRange(id value, long long *start, long long *end) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSArray *parts = [value componentsSeparatedByString:@"-"];
    if (parts.count != 2) return NO;
    *start = [parts[0] longLongValue];
    *end = [parts[1] longLongValue];
    return *end >= *start;
}

// Returns segments as @[offset, length, duration] or nil if the index can't be used.
NSArray *RWParseSidx(NSData *data, long long indexStart) {
    const uint8_t *b = data.bytes;
    long long n = (long long)data.length;
    if (indexStart < 0 || indexStart + 32 > n) return nil;
    const uint8_t *p = b + indexStart;
    uint64_t boxSize = RWBE32(p);
    if (memcmp(p + 4, "sidx", 4) != 0 || boxSize < 32 || indexStart + (long long)boxSize > n) return nil;
    uint8_t version = p[8];
    long long o = 12 + 4;                       // header + version/flags, skip reference_ID
    uint32_t timescale = RWBE32(p + o); o += 4;
    if (timescale == 0) return nil;
    uint64_t firstOffset;
    if (version == 0) { o += 4; firstOffset = RWBE32(p + o); o += 4; }
    else { o += 8; firstOffset = RWBE64(p + o); o += 8; }
    o += 2;                                     // reserved
    uint16_t count = (uint16_t)((p[o] << 8) | p[o + 1]); o += 2;
    if (count == 0 || o + 12LL * count > (long long)boxSize) return nil;

    NSMutableArray *segments = [NSMutableArray arrayWithCapacity:count];
    long long offset = indexStart + (long long)boxSize + (long long)firstOffset;
    for (uint16_t i = 0; i < count; i++, o += 12) {
        uint32_t ref = RWBE32(p + o);
        if (ref & 0x80000000u) return nil;     // nested index; YouTube doesn't use it
        long long size = ref & 0x7fffffffu;
        double duration = (double)RWBE32(p + o + 4) / timescale;
        [segments addObject:@[@(offset), @(size), @(duration)]];
        offset += size;
    }
    return segments;
}

NSString *RWMediaPlaylist(NSString *mediaName, long long initLength, NSArray *segments) {
    double maxDuration = 1;
    for (NSArray *s in segments) maxDuration = MAX(maxDuration, [s[2] doubleValue]);
    NSMutableString *m = [NSMutableString string];
    [m appendString:@"#EXTM3U\n#EXT-X-VERSION:7\n"];
    [m appendFormat:@"#EXT-X-TARGETDURATION:%ld\n", (long)ceil(maxDuration)];
    [m appendString:@"#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"];
    [m appendFormat:@"#EXT-X-MAP:URI=\"%@\",BYTERANGE=\"%lld@0\"\n", mediaName, initLength];
    for (NSArray *s in segments) {
        [m appendFormat:@"#EXTINF:%.5f,\n#EXT-X-BYTERANGE:%lld@%lld\n%@\n",
            [s[2] doubleValue], [s[1] longLongValue], [s[0] longLongValue], mediaName];
    }
    [m appendString:@"#EXT-X-ENDLIST\n"];
    return m;
}

static NSString *RWCodecs(NSDictionary *format) {
    NSString *type = [format[@"type"] description];
    NSRange r = [type rangeOfString:@"codecs=\""];
    if (r.location == NSNotFound) return nil;
    NSString *rest = [type substringFromIndex:NSMaxRange(r)];
    NSRange q = [rest rangeOfString:@"\""];
    return q.location == NSNotFound ? rest : [rest substringToIndex:q.location];
}

static long long RWBitrate(NSDictionary *f) {
    long long b = [[f[@"bitrate"] description] longLongValue];
    return b > 0 ? b : 500000;
}

#pragma mark - Server

@interface RWHLSSession : NSObject
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *playlists;   // name → text
@property (nonatomic, copy) NSDictionary<NSString *, NSURL *> *media;          // name → upstream URL
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *mediaLength;
@end
@implementation RWHLSSession
@end

@implementation RWStreamServer {
    int _listenFD;
    uint16_t _port;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, RWHLSSession *> *_sessions;
    NSMutableArray<NSString *> *_sessionOrder;
}

+ (instancetype)shared {
    static RWStreamServer *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        _queue = dispatch_queue_create("rewind.stream-server", DISPATCH_QUEUE_SERIAL);
        _sessions = [NSMutableDictionary dictionary];
        _sessionOrder = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willEnterForeground)
                                                     name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

// iOS may reclaim listening sockets while the app is suspended; re-open on the same port.
- (void)willEnterForeground {
    dispatch_async(_queue, ^{ [self restart]; });
}

- (void)stopLocked {
    if (_acceptSource) { dispatch_source_cancel(_acceptSource); _acceptSource = nil; }
    else if (_listenFD >= 0) close(_listenFD);
    _listenFD = -1;
}

- (void)restart {
    [self stopLocked];
    [self startLocked];
}

- (BOOL)startLocked {
    if (_listenFD >= 0) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    uint16_t wanted = _port ? _port : RWPreferredPort;
    addr.sin_port = htons(wanted);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        addr.sin_port = 0;   // preferred port busy: let the system pick
        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return NO; }
    }
    if (listen(fd, 32) != 0) { close(fd); return NO; }
    socklen_t len = sizeof(addr);
    getsockname(fd, (struct sockaddr *)&addr, &len);
    _port = ntohs(addr.sin_port);
    _listenFD = fd;

    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    __weak RWStreamServer *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        int client = accept(fd, NULL, NULL);
        if (client < 0) {
            if (errno != EAGAIN && errno != EINTR && errno != ECONNABORTED) [weakSelf restart];
            return;
        }
        int one = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        struct timeval tv = {30, 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf handleClient:client];
        });
    });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    _acceptSource = source;
    dispatch_resume(source);
    return YES;
}

- (RWHLSSession *)sessionNamed:(NSString *)sid {
    __block RWHLSSession *s = nil;
    dispatch_sync(_queue, ^{ s = self->_sessions[sid]; });
    return s;
}

#pragma mark Preparing a video

- (void)prepareVideoFormats:(NSArray<NSDictionary *> *)videos audio:(NSDictionary *)audio
                 completion:(void (^)(NSURL *, NSError *))completion {
    void (^fail)(NSString *) = ^(NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"Rewind" code:2 userInfo:@{NSLocalizedDescriptionKey: msg}]);
        });
    };
    if (!videos.count || !audio) { fail(@"no H.264 + AAC streams"); return; }

    NSMutableArray *formats = [NSMutableArray arrayWithArray:videos];
    [formats addObject:audio];
    NSMutableArray *names = [NSMutableArray array];
    for (NSUInteger i = 0; i < videos.count; i++) [names addObject:[NSString stringWithFormat:@"v%lu", (unsigned long)i]];
    [names addObject:@"a"];

    NSMutableDictionary *playlists = [NSMutableDictionary dictionary];
    NSMutableDictionary *media = [NSMutableDictionary dictionary];
    NSMutableDictionary *lengths = [NSMutableDictionary dictionary];
    NSMutableArray *errors = [NSMutableArray array];
    NSLock *lock = [NSLock new];
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger i = 0; i < formats.count; i++) {
        NSDictionary *f = formats[i];
        NSString *name = names[i];
        long long initStart, initEnd, indexStart, indexEnd;
        NSURL *url = RWResolveURL(f[@"url"]);
        if (!url || !RWParseRange(f[@"init"], &initStart, &initEnd) || !RWParseRange(f[@"index"], &indexStart, &indexEnd)) {
            [errors addObject:@"the server gave no segment index"];
            continue;
        }
        dispatch_group_enter(group);
        NSString *range = [NSString stringWithFormat:@"bytes=0-%lld", indexEnd];
        [[RWNetwork shared] fetchURL:url range:range completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            NSArray *segments = data ? RWParseSidx(data, indexStart) : nil;
            [lock lock];
            if (segments.count) {
                NSString *file = [name stringByAppendingString:@".mp4"];
                playlists[[name stringByAppendingString:@".m3u8"]] = RWMediaPlaylist(file, initEnd + 1, segments);
                media[file] = url;
                lengths[file] = @([[f[@"clen"] description] longLongValue]);
            } else {
                [errors addObject:error.localizedDescription ?: [NSString stringWithFormat:@"stream index unreadable (HTTP %ld)", (long)response.statusCode]];
            }
            [lock unlock];
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, _queue, ^{
        if (!playlists[@"a.m3u8"]) { fail(errors.firstObject ?: @"audio stream unavailable"); return; }
        NSMutableString *master = [NSMutableString stringWithString:@"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"];
        NSString *audioCodec = RWCodecs(audio) ?: @"mp4a.40.2";
        [master appendString:@"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Default\",DEFAULT=YES,AUTOSELECT=YES,URI=\"a.m3u8\"\n"];
        NSUInteger variants = 0;
        for (NSUInteger i = 0; i < videos.count; i++) {
            NSString *name = names[i];
            if (!playlists[[name stringByAppendingString:@".m3u8"]]) continue;
            NSDictionary *v = videos[i];
            long long bandwidth = (long long)(RWBitrate(v) * 1.25) + RWBitrate(audio);
            [master appendFormat:@"#EXT-X-STREAM-INF:BANDWIDTH=%lld,CODECS=\"%@,%@\"", bandwidth, RWCodecs(v) ?: @"avc1.4d401e", audioCodec];
            id size = v[@"size"];
            if ([size isKindOfClass:[NSString class]] && [size rangeOfString:@"x"].location != NSNotFound)
                [master appendFormat:@",RESOLUTION=%@", size];
            [master appendFormat:@",AUDIO=\"aud\"\n%@.m3u8\n", name];
            variants++;
        }
        if (!variants) { fail(errors.firstObject ?: @"video stream unavailable"); return; }
        playlists[@"master.m3u8"] = master;

        if (![self startLocked]) { fail(@"couldn't start the local stream server"); return; }
        RWHLSSession *session = [RWHLSSession new];
        session.playlists = playlists;
        session.media = media;
        session.mediaLength = lengths;
        NSString *sid = [[NSUUID UUID].UUIDString substringToIndex:8].lowercaseString;
        self->_sessions[sid] = session;
        [self->_sessionOrder addObject:sid];
        while (self->_sessionOrder.count > 4) {
            [self->_sessions removeObjectForKey:self->_sessionOrder.firstObject];
            [self->_sessionOrder removeObjectAtIndex:0];
        }
        NSURL *masterURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/%@/master.m3u8", self->_port, sid]];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(masterURL, nil); });
    });
}

#pragma mark HTTP

static const long long RWMaxChunk = 4LL * 1024 * 1024;

NSString *RWClampRange(NSString *range, long long total) {
    long long start = 0, end = -1;
    NSString *spec = [range hasPrefix:@"bytes="] ? [range substringFromIndex:6] : nil;
    NSArray *ab = [spec componentsSeparatedByString:@"-"];
    if (ab.count == 2 && [ab[0] length]) {
        start = [ab[0] longLongValue];
        if ([ab[1] length]) end = [ab[1] longLongValue];
    } else if (range.length) {
        return range;   // suffix or multi-range: pass through untouched
    }
    if (end < 0 || end - start + 1 > RWMaxChunk) end = start + RWMaxChunk - 1;
    if (total > 0 && end > total - 1) end = total - 1;
    return [NSString stringWithFormat:@"bytes=%lld-%lld", start, end];
}

static BOOL RWSendAll(int fd, const void *bytes, size_t length) {
    const uint8_t *p = bytes;
    while (length > 0) {
        ssize_t n = send(fd, p, length, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        p += n; length -= (size_t)n;
    }
    return YES;
}

static void RWRespond(int fd, NSInteger status, NSString *reason, NSDictionary *headers, NSData *body, BOOL head) {
    NSMutableString *h = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, reason];
    for (NSString *key in headers) [h appendFormat:@"%@: %@\r\n", key, headers[key]];
    [h appendFormat:@"Content-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
    NSData *headerData = [h dataUsingEncoding:NSUTF8StringEncoding];
    if (RWSendAll(fd, headerData.bytes, headerData.length) && body.length && !head) RWSendAll(fd, body.bytes, body.length);
}

- (void)handleClient:(int)fd {
    @autoreleasepool {
        char buffer[16384];
        size_t used = 0;
        while (used < sizeof(buffer) - 1) {
            ssize_t n = recv(fd, buffer + used, sizeof(buffer) - 1 - used, 0);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            used += (size_t)n;
            buffer[used] = 0;
            if (strstr(buffer, "\r\n\r\n")) break;
        }
        buffer[used] = 0;
        NSString *request = [[NSString alloc] initWithBytes:buffer length:used encoding:NSISOLatin1StringEncoding];
        NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
        NSArray *first = [lines.firstObject componentsSeparatedByString:@" "];
        if (first.count < 2) { close(fd); return; }
        NSString *method = first[0];
        BOOL head = [method isEqualToString:@"HEAD"];
        NSString *path = [first[1] componentsSeparatedByString:@"?"].firstObject;
        NSString *range = nil;
        for (NSString *line in lines) {
            if ([line.lowercaseString hasPrefix:@"range:"]) range = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }

        NSArray *parts = [path componentsSeparatedByString:@"/"];   // "", sid, name
        RWHLSSession *session = parts.count == 3 ? [self sessionNamed:parts[1]] : nil;
        NSString *name = parts.count == 3 ? parts[2] : nil;
        if (!session) { RWRespond(fd, 404, @"Not Found", @{}, nil, head); close(fd); return; }

        NSString *playlist = session.playlists[name];
        if (playlist) {
            RWRespond(fd, 200, @"OK", @{@"Content-Type": @"application/vnd.apple.mpegurl", @"Cache-Control": @"no-cache"},
                      [playlist dataUsingEncoding:NSUTF8StringEncoding], head);
            close(fd);
            return;
        }
        NSURL *upstream = session.media[name];
        if (!upstream) { RWRespond(fd, 404, @"Not Found", @{}, nil, head); close(fd); return; }
        NSString *contentType = [name hasPrefix:@"a"] ? @"audio/mp4" : @"video/mp4";
        long long total = [session.mediaLength[name] longLongValue];

        if (head) {
            NSMutableString *s = [NSMutableString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nAccept-Ranges: bytes\r\n", contentType];
            if (total > 0) [s appendFormat:@"Content-Length: %lld\r\n", total];
            [s appendString:@"Connection: close\r\n\r\n"];
            NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
            RWSendAll(fd, d.bytes, d.length);
            close(fd);
            return;
        }

        // Players sometimes ask for "everything from byte N"; answering that means downloading
        // the whole rest of the file before sending a byte. Serve at most 4 MB per request
        // instead (a shorter 206 is valid HTTP; the player asks again for the rest).
        range = RWClampRange(range, total);

        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSData *body = nil;
        __block NSHTTPURLResponse *response = nil;
        [[RWNetwork shared] fetchURL:upstream range:range completion:^(NSData *data, NSHTTPURLResponse *r, NSError *error) {
            body = data; response = r;
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)));

        NSInteger status = response.statusCode;
        if (!body || status >= 400 || status == 0) {
            RWRespond(fd, status >= 400 ? status : 502, @"Upstream Error", @{@"Content-Type": @"text/plain"},
                      [@"upstream failed" dataUsingEncoding:NSUTF8StringEncoding], NO);
            close(fd);
            return;
        }
        NSMutableDictionary *headers = [@{@"Content-Type": contentType, @"Accept-Ranges": @"bytes"} mutableCopy];
        NSString *contentRange = nil;
        for (NSString *key in response.allHeaderFields)
            if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) contentRange = response.allHeaderFields[key];
        if (status == 206 && contentRange) {
            headers[@"Content-Range"] = contentRange;
            RWRespond(fd, 206, @"Partial Content", headers, body, NO);
        } else if (range && status == 200) {
            // Upstream ignored Range: cut the requested slice out ourselves.
            long long a = 0, b = (long long)body.length - 1;
            NSString *spec = [range hasPrefix:@"bytes="] ? [range substringFromIndex:6] : range;
            NSArray *ab = [spec componentsSeparatedByString:@"-"];
            if (ab.count == 2) {
                a = [ab[0] longLongValue];
                if ([ab[1] length]) b = MIN([ab[1] longLongValue], (long long)body.length - 1);
            }
            if (a > b || a >= (long long)body.length) {
                RWRespond(fd, 416, @"Range Not Satisfiable", @{}, nil, NO);
            } else {
                headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lld-%lld/%lu", a, b, (unsigned long)body.length];
                RWRespond(fd, 206, @"Partial Content", headers, [body subdataWithRange:NSMakeRange((NSUInteger)a, (NSUInteger)(b - a + 1))], NO);
            }
        } else {
            RWRespond(fd, 200, @"OK", headers, body, NO);
        }
        close(fd);
    }
}

@end
