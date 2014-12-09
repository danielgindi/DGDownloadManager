//
//  DGDownloadManagerFile.m
//  DGDownloadManager
//
//  Created by Daniel Cohen Gindi on 12/29/13.
//  Copyright (c) 2013 Daniel Cohen Gindi. All rights reserved.
//
//  https://github.com/danielgindi/DGDownloadManager
//
//  The MIT License (MIT)
//
//  Copyright (c) 2014 Daniel Cohen Gindi (danielgindi@gmail.com)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

#import "DGDownloadManagerFile.h"
#import "DGDownloadManager.h"

@interface DGDownloadManagerFile () <NSURLConnectionDelegate, NSURLConnectionDataDelegate>
@end

@implementation DGDownloadManagerFile
{
    NSURLConnection *_connection;
    NSFileHandle *fileWriteHandle;
    BOOL resumeAllowed;
    BOOL connectionFinished;
    UIBackgroundTaskIdentifier bgTaskId;
    
    NSString *_downloadFilePath;
    BOOL _shouldDeleteOnDealloc;
    NSURLRequest *_currentUrlRequest;
}

- (void)initialize_DGDownloadManagerFile
{
    _requestTimeout = 60.0;
    _cachePolicy = NSURLRequestUseProtocolCachePolicy;
    bgTaskId = UIBackgroundTaskInvalid;
}

- (id)initWithUrl:(NSURL *)url
{
    self = [super init];
    if (self)
    {
        [self initialize_DGDownloadManagerFile];
        _url = url;
    }
    return self;
}

- (id)initWithUrl:(NSURL *)url context:(NSObject *)context
{
    self = [super init];
    if (self)
    {
        [self initialize_DGDownloadManagerFile];
        _url = url;
        _context = context;
    }
    return self;
}

- (id)initWithUrlRequest:(NSURLRequest *)urlRequest context:(NSObject *)context
{
    self = [super init];
    if (self)
    {
        [self initialize_DGDownloadManagerFile];
        _urlRequest = urlRequest;
        _context = context;
    }
    return self;
}

- (id)initWithUrlRequest:(NSURLRequest *)urlRequest
{
    self = [super init];
    if (self)
    {
        [self initialize_DGDownloadManagerFile];
        _urlRequest = urlRequest;
    }
    return self;
}

- (void)dealloc
{
    [self cancelDownloading];
    [fileWriteHandle closeFile];
    fileWriteHandle = nil;
    
    if (_downloadFilePath && _shouldDeleteOnDealloc)
    {
        [[NSFileManager defaultManager] removeItemAtPath:_downloadFilePath error:nil];
    }
}

- (NSString *)newTempFilePath
{
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    CFStringRef uuidStr = CFUUIDCreateString(NULL, uuid);
    
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"download-%@", uuidStr]];
    
    CFRelease(uuidStr);
    CFRelease(uuid);
    
    return path;
}

- (BOOL)prepareFileForDownloadWithResume:(BOOL)isResume error:(NSError **)outError
{
    BOOL shouldReturnError = NO;
    
    if (isResume && _downloadFilePath) return NO;
    
    if (!_downloadFilePath || !isResume)
    {
        _downloadFilePath = self.downloadDirectlyToPath;
        
        if (_downloadFilePath)
        {
            _shouldDeleteOnDealloc = NO;
            
            BOOL isDirectory = NO;
            if (!isResume || ![[NSFileManager defaultManager] fileExistsAtPath:_downloadFilePath isDirectory:&isDirectory] || isDirectory)
            {
                NSError *fileCreationError = nil;
                [[[NSData alloc] init] writeToFile:_downloadFilePath options:0 error:&fileCreationError];
                
                if (fileCreationError)
                {
                    _downloadFilePath = nil;
                    if (outError)
                    {
                        *outError = fileCreationError;
                    }
                    shouldReturnError = YES;
                }
            }
        }
        else
        {
            _shouldDeleteOnDealloc = YES;
            
            NSError *fileCreationError = nil;
            
            _downloadFilePath = [self newTempFilePath];
            int tries = 3;
            
            [[[NSData alloc] init] writeToFile:_downloadFilePath options:0 error:&fileCreationError];
            while (fileCreationError && --tries)
            {
                _downloadFilePath = [self newTempFilePath];
                
                fileCreationError = nil;
                [[[NSData alloc] init] writeToFile:_downloadFilePath options:0 error:&fileCreationError];
            }
            
            if (fileCreationError)
            {
                _downloadFilePath = nil;
                if (outError)
                {
                    *outError = fileCreationError;
                }
                shouldReturnError = YES;
            }
        }
    }
    
    // Now when we have a file (and truncated it if we needed to) open a handle for writing to it.
    // On UNIX the file can be moved or even deleted while the handle is still open - which is a nice feature because we can start reading from the temp file while downloading, and when we move that file to somewhere else we don't have to stop and resume reading.
    if (_downloadFilePath)
    {
        fileWriteHandle = [NSFileHandle fileHandleForWritingAtPath:_downloadFilePath];
        if (!fileWriteHandle)
        {
            _downloadFilePath = nil;
            if (outError)
            {
                *outError = [NSError errorWithDomain:@"file.io" code:0 userInfo:@{NSLocalizedDescriptionKey: @"NSFileHandle fileHandleForWritingAtPath: failed and returned nil."}];
            }
            shouldReturnError = YES;
        }
    }
    
    return shouldReturnError;
}

- (void)startDownloadingNow
{
    if (_connection || (!_url && !_urlRequest)) return;
    
    _currentUrlRequest = _urlRequest;
    if (!_currentUrlRequest)
    {
        _currentUrlRequest = [[NSURLRequest alloc] initWithURL:_url cachePolicy:_cachePolicy timeoutInterval:_requestTimeout];
    }
    
    NSError *fileError = nil;
    [self prepareFileForDownloadWithResume:NO error:&fileError];
    
    if (fileError)
    {
        [self connection:nil didFailWithError:fileError];
        return;
    }
    
    _connection = [[NSURLConnection alloc] initWithRequest:_currentUrlRequest delegate:self];
    connectionFinished = NO;
    [_connection start];
    
    if (!_isStandalone)
    {
        [[DGDownloadManager sharedInstance] downloadFile:self];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:DGDownloadManagerDownloadStartedNotification object:self];
    if (_delegate && [_delegate respondsToSelector:@selector(downloadManagerFileStartedDownload:)])
    {
        [_delegate downloadManagerFileStartedDownload:self];
    }
}

- (void)pauseDownloading
{
    if (!_connection) return;
    [_connection cancel];
    _connection = nil;
    _currentUrlRequest = nil;
    
    if (!_isStandalone)
    {
        [[DGDownloadManager sharedInstance] cancelFileDownload:self];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:DGDownloadManagerDownloadPausedNotification object:self];
    if (_delegate && [_delegate respondsToSelector:@selector(downloadManagerFilePausedDownload:)])
    {
        [_delegate downloadManagerFilePausedDownload:self];
    }
    
    if (bgTaskId)
    {
        [UIApplication.sharedApplication endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }
}

- (void)cancelDownloading
{
    if (!_connection) return;
    [_connection cancel];
    _connection = nil;
    _currentUrlRequest = nil;
    
    [fileWriteHandle closeFile];
    fileWriteHandle = nil;
    
    if (_downloadFilePath && _shouldDeleteOnDealloc)
    {
        [[NSFileManager defaultManager] removeItemAtPath:_downloadFilePath error:nil];
        _downloadFilePath = nil;
        _shouldDeleteOnDealloc = NO;
    }
    
    _downloadedDataLength = 0LL;
    
    if (!_isStandalone)
    {
        [[DGDownloadManager sharedInstance] cancelFileDownload:self];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:DGDownloadManagerDownloadCancelledNotification object:self];
    if (_delegate && [_delegate respondsToSelector:@selector(downloadManagerFileCancelledDownload:)])
    {
        [_delegate downloadManagerFileCancelledDownload:self];
    }
    
    if (bgTaskId)
    {
        [UIApplication.sharedApplication endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }
}

- (void)resumeDownloadNow
{
    if (_connection || (!_url && !_urlRequest)) return;
    
    NSError *fileError = nil;
    [self prepareFileForDownloadWithResume:YES error:&fileError];
    
    if (fileError)
    {
        [self connection:nil didFailWithError:fileError];
        return;
    }
    
    NSMutableURLRequest *request;
    
    if (_urlRequest)
    {
        request = [_urlRequest mutableCopy];
    }
    else
    {
        request = [NSMutableURLRequest requestWithURL:_url cachePolicy:_cachePolicy timeoutInterval:_requestTimeout];
    }
    
    unsigned long long currentFileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:_downloadFilePath error:nil] fileSize];
    _downloadedDataLength = currentFileSize;
    
    if (resumeAllowed)
    {
        if ([request valueForHTTPHeaderField:@"Range"] == nil)
        {
            [request addValue:[NSString stringWithFormat:@"bytes=%lld-", _downloadedDataLength] forHTTPHeaderField:@"Range"];
        }
    }
    else
    {
        [request setValue:nil forHTTPHeaderField:@"Range"];
    }
    
    _currentUrlRequest = [request copy];
    
    bgTaskId = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        bgTaskId = UIBackgroundTaskInvalid;
        [self cancelDownloading];
    }];
    _connection = [[NSURLConnection alloc] initWithRequest:_currentUrlRequest delegate:self];
    connectionFinished = NO;
    [_connection start];
    
    if (!_isStandalone)
    {
        [[DGDownloadManager sharedInstance] resumeFileDownload:self];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:DGDownloadManagerDownloadStartedNotification object:self];
    if (_delegate && [_delegate respondsToSelector:@selector(downloadManagerFileStartedDownload:)])
    {
        [_delegate downloadManagerFileStartedDownload:self];
    }
}

- (void)addToDownloadQueue
{
    [[DGDownloadManager sharedInstance] downloadFile:self];
}

- (void)addToDownloadQueueForResuming
{
    [[DGDownloadManager sharedInstance] resumeFileDownload:self];
}

- (void)postFailedMessageWithError:(NSError *)error
{
    [[NSNotificationCenter defaultCenter] postNotificationName:DGDownloadManagerDownloadFailedNotification object:self userInfo:@{@"error": error}];
    
    if (_delegate)
    {
        if ([_delegate respondsToSelector:@selector(downloadManagerFileFailedDownload:error:)])
        {
            [_delegate downloadManagerFileFailedDownload:self error:error];
        }
        else if ([_delegate respondsToSelector:@selector(downloadManagerFileFailedDownload:)])
        {
            [_delegate downloadManagerFileFailedDownload:self];
        }
    }
}

#pragma mark - Accessors

- (BOOL)isComplete
{
    return (_expectedContentLength == -1 || (unsigned long long)_expectedContentLength == _downloadedDataLength) && connectionFinished;
}

- (BOOL)isDownloading
{
    return _connection != nil;
}

- (NSString *)downloadedFilePath
{
    return _downloadFilePath;
}

#pragma mark - NSURLConnectionDelegate, NSURLConnectionDataDelegate

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response
{
    _suggestedFilename = response.suggestedFilename;
    if (response)
    {
        NSMutableURLRequest *goodRequest = [_currentUrlRequest mutableCopy];
        goodRequest.URL = request.URL;
        return goodRequest;
    }
    else
    {
        return request;
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    if ([response isKindOfClass:NSHTTPURLResponse.class])
    {
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (statusCode >= 400)
        {
            [connection cancel];
            [self connection:connection didFailWithError:[NSError errorWithDomain:response.URL.absoluteString code:statusCode userInfo:@{ NSLocalizedFailureReasonErrorKey: @(statusCode)}]];
            return;
        }
    }
    
    _suggestedFilename = response.suggestedFilename;
    _expectedContentLength = response.expectedContentLength;
    
    NSHTTPURLResponse *httpResonse = (NSHTTPURLResponse *)response;
    NSDictionary *headers = [httpResonse allHeaderFields];
    
    resumeAllowed = [[headers valueForKey:@"Accept-Ranges"] hasSuffix:@"bytes"];
    
    long long start = 0;
    
    NSString *contentRange = [headers valueForKey:@"Content-Range"];
    if (contentRange && _downloadedDataLength > 0ULL)
    {
        NSScanner *contentRangeScanner = [NSScanner scannerWithString:contentRange];
        [contentRangeScanner scanString:@"bytes " intoString:nil];
        [contentRangeScanner scanLongLong:&start];
        
        _expectedContentLength += start;
    }
    
    if (start > 0L)
    {
        // This is a partial, from resuming the download. Seek to the start position.
        [fileWriteHandle seekToFileOffset:start];
    }
    else
    {
        /*! @discussion In rare cases, for example in the case of an HTTP load where the content type of the load data is multipart/x-mixed-replace, the delegate will receive more than one connection:didReceiveResponse: message. In the event this occurs, delegates should discard all data previously delivered by connection:didReceiveData:, and should be prepared to handle the, potentially different, MIME type reported by the newly reported URL response. */
        
        [fileWriteHandle truncateFileAtOffset:0];
        _downloadedDataLength = 0ULL;
    }
    
    if (_delegate && [_delegate respondsToSelector:@selector(downloadManagerFileHeadersReceived:)])
    {
        [_delegate downloadManagerFileHeadersReceived:self];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    @try
    {
        [fileWriteHandle writeData:data];
    }
    @catch (NSException *exception)
    {
        [connection cancel];
        
        NSMutableDictionary *userInfo = [exception.userInfo mutableCopy];
        userInfo[NSLocalizedFailureReasonErrorKey] = exception.reason;
        
        NSError *error = [NSError errorWithDomain:@"file.io"
                                             code:0
                                         userInfo:userInfo];
        [self connection:connection didFailWithError:error];
        
        return;
    }
    @finally
    {
        
    }
    
    [fileWriteHandle synchronizeFile]; // Prevent memory presure by always flushing to disk
    _downloadedDataLength += (unsigned long long)data.length;
    
    if (_progressDelegate)
    {
        [_progressDelegate downloadManagerFileProgressChanged:self];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    _connection = nil;
    _currentUrlRequest = nil;
    
    if (!_isStandalone)
    {
        // Make it remove from us the known arrays
        [[DGDownloadManager sharedInstance] cancelFileDownload:self];
    }
    
    [self postFailedMessageWithError:error];
    
    if (bgTaskId)
    {
        [UIApplication.sharedApplication endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    _connection = nil;
    _currentUrlRequest = nil;
    connectionFinished = YES;
    
    if (!_isStandalone)
    {
        // Make it remove from us the known arrays
        [[DGDownloadManager sharedInstance] cancelFileDownload:self];
    }
    
    if ([[[NSFileManager defaultManager] attributesOfItemAtPath:_downloadFilePath error:nil] fileSize] < _downloadedDataLength)
    {
        NSError *error = [NSError errorWithDomain:@"file.io" code:0 userInfo:@{NSLocalizedDescriptionKey: @"seems like we ran out of space and could not write to disk"}];
        
        [self postFailedMessageWithError:error];
    }
    else
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:DGDownloadManagerDownloadFinishedNotification object:self];
        if (_delegate && [_delegate respondsToSelector:@selector(downloadManagerFileFinishedDownload:)])
        {
            [_delegate downloadManagerFileFinishedDownload:self];
        }
    }
    
    if (bgTaskId)
    {
        [UIApplication.sharedApplication endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }
}

@end
