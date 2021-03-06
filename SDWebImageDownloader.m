/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import <objc/message.h>
#import "SDWebImageDownloader.h"

#ifdef ENABLE_SDWEBIMAGE_DECODER
#import "SDWebImageDecoder.h"
@interface SDWebImageDownloader (ImageDecoder) <SDWebImageDecoderDelegate>
@end
#endif

NSString *const SDWebImageDownloadStartNotification = @"SDWebImageDownloadStartNotification";
NSString *const SDWebImageDownloadStopNotification = @"SDWebImageDownloadStopNotification";

@interface SDWebImageDownloader ()
@property (nonatomic, retain) NSURLConnection *connection;
@end

@implementation SDWebImageDownloader
@synthesize url, delegate, connection, imageData, etag, userInfo, lowPriority, httpHeaders, statusCode;

#pragma mark Public Methods

+ (id)downloaderWithURL:(NSURL *)url delegate:(id<SDWebImageDownloaderDelegate>)delegate
{
    return [self downloaderWithURL:url delegate:delegate userInfo:nil];
}

+ (id)downloaderWithURL:(NSURL *)url delegate:(id<SDWebImageDownloaderDelegate>)delegate httpHeaders:(NSDictionary *)httpHeaders
{
    return [self downloaderWithURL:url delegate:delegate userInfo:nil lowPriority:NO httpHeaders:httpHeaders];
}

+ (id)downloaderWithURL:(NSURL *)url delegate:(id<SDWebImageDownloaderDelegate>)delegate userInfo:(id)userInfo
{

    return [self downloaderWithURL:url delegate:delegate userInfo:userInfo lowPriority:NO httpHeaders:nil];
}

+ (id)downloaderWithURL:(NSURL *)url delegate:(id<SDWebImageDownloaderDelegate>)delegate userInfo:(id)userInfo lowPriority:(BOOL)lowPriority httpHeaders:(NSDictionary *)httpHeaders
{
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    if (NSClassFromString(@"SDNetworkActivityIndicator"))
    {
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }

    SDWebImageDownloader *downloader = [[[SDWebImageDownloader alloc] init] autorelease];
    downloader.url = url;
    downloader.delegate = delegate;
    downloader.userInfo = userInfo;
    downloader.lowPriority = lowPriority;
    downloader.httpHeaders = httpHeaders;
    [downloader performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:YES];
    return downloader;
}

+ (void)setMaxConcurrentDownloads:(NSUInteger)max
{
    // NOOP
}

- (void)start
{
    // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    if ( self.httpHeaders ) {
        for (NSString *key in [self.httpHeaders allKeys]) {
            [request setValue:[self.httpHeaders objectForKey:key] forHTTPHeaderField:key];
        }
    }
    self.connection = [[[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO] autorelease];

    // If not in low priority mode, ensure we aren't blocked by UI manipulations (default runloop mode for NSURLConnection is NSEventTrackingRunLoopMode)
    if (!lowPriority)
    {
        [connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    }
    [connection start];
    [request release];

    if (connection)
    {
        self.imageData = [NSMutableData data];
        [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStartNotification object:nil];
    }
    else
    {
        if ([delegate respondsToSelector:@selector(imageDownloader:didFailWithError:)])
        {
            [delegate performSelector:@selector(imageDownloader:didFailWithError:) withObject:self withObject:nil];
        }
    }
}

- (void)cancel
{
    if (connection)
    {
        [connection cancel];
        self.connection = nil;
        [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:nil];
    }
}

#pragma mark NSURLConnection (delegate)

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpurlResponse = (NSHTTPURLResponse *)response;
        NSDictionary *headers = [httpurlResponse allHeaderFields];
        self.etag = [headers objectForKey:@"Etag"];
        self.statusCode = [httpurlResponse statusCode];
    }
}

- (void)connection:(NSURLConnection *)aConnection didReceiveData:(NSData *)data
{
    [imageData appendData:data];
}

#pragma GCC diagnostic ignored "-Wundeclared-selector"
- (void)connectionDidFinishLoading:(NSURLConnection *)aConnection
{
    self.connection = nil;

    [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:nil];

    if ([delegate respondsToSelector:@selector(imageDownloaderDidFinish:)])
    {
        [delegate performSelector:@selector(imageDownloaderDidFinish:) withObject:self];
    }

    if (self.statusCode == 304) {
        if ([delegate respondsToSelector:@selector(imageDownloaderDidFinishWithSameImage:)])
        {
            ((void(*)(id, SEL, id))objc_msgSend)(delegate, @selector(imageDownloaderDidFinishWithSameImage:), self);
        }
    } else {
        if ([delegate respondsToSelector:@selector(imageDownloader:didFinishWithImage:andEtag:)]) {
            UIImage *image = [[UIImage alloc] initWithData:imageData];
            NSString *etagCopy = nil;
            if (self.etag) {
                etagCopy = [NSString stringWithString:self.etag];
            }

#ifdef ENABLE_SDWEBIMAGE_DECODER
            [[SDWebImageDecoder sharedImageDecoder] decodeImage:image withDelegate:self userInfo:nil];
#else
            ((void(*)(id, SEL, id, UIImage *, NSString *))objc_msgSend)(delegate, @selector(imageDownloader:didFinishWithImage:andEtag:), self, image, etagCopy);
#endif
            [image release];
        }
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:nil];

    if ([delegate respondsToSelector:@selector(imageDownloader:didFailWithError:)])
    {
        [delegate performSelector:@selector(imageDownloader:didFailWithError:) withObject:self withObject:error];
    }

    self.connection = nil;
    self.imageData = nil;
    self.etag = nil;
}

#pragma mark SDWebImageDecoderDelegate

#ifdef ENABLE_SDWEBIMAGE_DECODER
- (void)imageDecoder:(SDWebImageDecoder *)decoder didFinishDecodingImage:(UIImage *)image userInfo:(NSDictionary *)userInfo
{
    [delegate performSelector:@selector(imageDownloader:didFinishWithImage:) withObject:self withObject:image];
}
#endif

#pragma mark NSObject

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [url release], url = nil;
    [connection release], connection = nil;
    [imageData release], imageData = nil;
    [etag release], etag = nil;
    [userInfo release], userInfo = nil;
    [httpHeaders release], httpHeaders = nil;
    [super dealloc];
}

//-(void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
//{
//    NSLog( @"didReceiveAuthenticationChallenge" );
//}

@end
