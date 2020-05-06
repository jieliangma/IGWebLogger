//
//  IGWebLoggerURLConnection.m
//  IGWebLogger
//
//  Created by Francis Chong on 13年3月4日.
//  Copyright (c) 2013年 Ignition Soft. All rights reserved.
//

#import "IGWebLoggerURLConnection.h"
#import "IGWebLoggerWebSocket.h"

#import <CocoaAsyncSocket/GCDAsyncSocket.h>

#import <CocoaHTTPServer/HTTPMessage.h>
#import <CocoaHTTPServer/HTTPResponse.h>
#import <CocoaHTTPServer/HTTPFileResponse.h>
#import <CocoaHTTPServer/HTTPDynamicFileResponse.h>
#import <CocoaHTTPServer/HTTPLogging.h>
#import <CocoaHTTPServer/MultipartFormDataParser.h>
#import <CocoaHTTPServer/MultipartMessageHeader.h>
#import <CocoaHTTPServer/MultipartMessageHeaderField.h>
#import <CocoaHTTPServer/HTTPRedirectResponse.h>

static const int httpLogLevel = HTTP_LOG_LEVEL_WARN | HTTP_LOG_FLAG_TRACE;

@interface IGWebLoggerURLConnection ()

@property (nonatomic, strong) MultipartFormDataParser *parser;
@property (nonatomic, strong) NSFileHandle *storeFile;
@property (nonatomic, strong) NSMutableArray<NSString *> *uploadedFiles;

@end

@implementation IGWebLoggerURLConnection

- (NSObject<HTTPResponse>*)httpResponseForMethod:(NSString *)method URI:(NSString *)path {
    HTTPLogTrace();

    // Replace %%WEBSOCKET_URL%% from websocket.js to the actual URL of the server
    if ([path isEqualToString:@"/index.html"] || [path isEqualToString:@"/"]) {
        NSString *wsLocation;
        NSString *wsHost = [request headerField:@"Host"];
        if (wsHost == nil) {
            NSString *port = [NSString stringWithFormat:@"%hu", [asyncSocket localPort]];
            wsLocation = [NSString stringWithFormat:@"ws://localhost:%@/service", port];
        } else {
            wsLocation = [NSString stringWithFormat:@"ws://%@/service", wsHost];
        }
        
        NSDictionary *replacementDict = [NSDictionary dictionaryWithObject:wsLocation
                                                                    forKey:@"WEBSOCKET_URL"];
        return [[HTTPDynamicFileResponse alloc] initWithFilePath:[self filePathForURI:path]
                                                   forConnection:self
                                                       separator:@"%%"
                                           replacementDictionary:replacementDict];
    }
    
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/"]) {
        return [[HTTPRedirectResponse alloc] initWithPath:@"/"];
    }
    return [super httpResponseForMethod:method URI:path];
}

- (WebSocket *)webSocketForURI:(NSString *)path {
    if([path isEqualToString:@"/service"]) {
        return [[IGWebLoggerWebSocket alloc] initWithRequest:request socket:asyncSocket];
    }
    return [super webSocketForURI:path];
}

- (BOOL)supportsMethod:(NSString *)method atPath:(NSString *)path {
    HTTPLogTrace();
    
    // Add support for POST
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/"]) {
        return YES;
    }
    return [super supportsMethod:method atPath:path];
}

- (BOOL)expectsRequestBodyFromMethod:(NSString *)method atPath:(NSString *)path {
    HTTPLogTrace();
    
    // Inform HTTP server that we expect a body to accompany a POST request
    if ([method isEqualToString:@"POST"] && ([path isEqualToString:@"/"] || [path length] == 0)) {
        // here we need to make sure, boundary is set in header
        NSString* contentType = [request headerField:@"Content-Type"];
        NSUInteger paramsSeparator = [contentType rangeOfString:@";"].location;
        if( NSNotFound == paramsSeparator ) {
            return NO;
        }
        if( paramsSeparator >= contentType.length - 1 ) {
            return NO;
        }
        NSString* type = [contentType substringToIndex:paramsSeparator];
        if( ![type isEqualToString:@"multipart/form-data"] ) {
            // we expect multipart/form-data content type
            return NO;
        }

        // enumerate all params in content-type, and find boundary there
        NSArray* params = [[contentType substringFromIndex:paramsSeparator + 1] componentsSeparatedByString:@";"];
        for( NSString* param in params ) {
            paramsSeparator = [param rangeOfString:@"="].location;
            if( (NSNotFound == paramsSeparator) || paramsSeparator >= param.length - 1 ) {
                continue;
            }
            NSString* paramName = [param substringWithRange:NSMakeRange(1, paramsSeparator-1)];
            NSString* paramValue = [param substringFromIndex:paramsSeparator+1];
            
            if( [paramName isEqualToString: @"boundary"] ) {
                // let's separate the boundary from content-type, to make it more handy to handle
                [request setHeaderField:@"boundary" value:paramValue];
            }
        }
        // check if boundary specified
        if( nil == [request headerField:@"boundary"] )  {
            return NO;
        }
        return YES;
    }
    return [super expectsRequestBodyFromMethod:method atPath:path];
}

- (void)prepareForBodyWithSize:(UInt64)contentLength {
    HTTPLogTrace();
    
    // set up mime parser
    NSString* boundary = [request headerField:@"boundary"];
    self.parser = [[MultipartFormDataParser alloc] initWithBoundary:boundary formEncoding:NSUTF8StringEncoding];
    self.parser.delegate = self;
    self.uploadedFiles = [[NSMutableArray alloc] init];
}

- (void)processBodyData:(NSData *)postDataChunk {
    HTTPLogTrace();
    // append data to the parser. It will invoke callbacks to let us handle
    // parsed data.
    [self.parser appendData:postDataChunk];
}


#pragma mark multipart form data parser delegate

- (void)processStartOfPartWithHeader:(MultipartMessageHeader *)header {
    // in this sample, we are not interested in parts, other then file parts.
    // check content disposition to find out filename

    MultipartMessageHeaderField *disposition = [header.fields objectForKey:@"Content-Disposition"];
    NSString* filename = [disposition.params objectForKey:@"filename"];

    if ([filename length] == 0) {
        // it's either not a file part, or
        // an empty form sent. we won't handle it.
        return;
    }
    
    NSString* uploadDirPath = [config documentRoot];
    NSString* filePath = [uploadDirPath stringByAppendingPathComponent:filename];
    NSString *directory = [filePath stringByDeletingLastPathComponent];
    NSFileManager *fileManager = [[NSFileManager alloc] init];

    // Ensure parent directory exist
    BOOL isDir = YES;
    BOOL bRet = YES;
    if (![fileManager fileExistsAtPath:directory isDirectory:&isDir]) {
        bRet = [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    } else if (!isDir) {
        [fileManager removeItemAtPath:directory error:nil];
        bRet = [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    if (bRet) {
        HTTPLogVerbose(@"Saving file to %@", filePath);
    } else {
        HTTPLogError(@"Could not create directory at path: %@", directory);
    }
    
    // Remove file if exist
    if ([fileManager fileExistsAtPath:filePath]) {
        [fileManager removeItemAtPath:filePath error:nil];
    }
    
    if(![fileManager createFileAtPath:filePath contents:nil attributes:nil]) {
        HTTPLogError(@"Could not create file at path: %@", filePath);
    }
    
    self.storeFile = [NSFileHandle fileHandleForWritingAtPath:filePath];
    [self.uploadedFiles addObject: filePath];
}

- (void)processContent:(NSData*)data WithHeader:(MultipartMessageHeader *) header {
    // here we just write the output from parser to the file.
    if (self.storeFile) {
        [self.storeFile writeData:data];
    }
}

- (void)processEndOfPartWithHeader:(MultipartMessageHeader *) header {
    // as the file part is over, we close the file.
    [self.storeFile closeFile];
    self.storeFile = nil;
}

- (void)processPreambleData:(NSData*) data {
    // if we are interested in preamble data, we could process it here.

}

- (void)processEpilogueData:(NSData*) data {
    // if we are interested in epilogue data, we could process it here.

}

@end
