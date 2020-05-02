//
//  IGWebLogger.m
//  IGWebLogger
//
//  Created by Francis Chong on 13年3月4日.
//  Copyright (c) 2013年 Ignition Soft. All rights reserved.
//

#import "IGWebLogger.h"
#import "WebSocket.h"
#import "HTTPServer.h"
#import "IGWebLoggerWebSocket.h"
#import "IGWebLoggerURLConnection.h"

@implementation IGWebLogger

static IGWebLogger *sharedInstance;

+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
		sharedInstance = [[IGWebLogger alloc] init];
    });
}

+ (IGWebLogger *)sharedInstance {
	return sharedInstance;
}

- (id)init {
	if (sharedInstance != nil) {
		return nil;
	}
	
	if ((self = [super init])) {
        self.webSockets = [NSMutableArray array];
	}

	return self;
}

#pragma mark - Public

- (void)addWebSocket:(WebSocket*)webSocket {
    dispatch_sync([DDLog loggingQueue], ^{
        [self.webSockets addObject:webSocket];
    });
}

- (void)removeWebSocket:(WebSocket*)webSocket {
    dispatch_sync([DDLog loggingQueue], ^{
        [self.webSockets removeObject:webSocket];
    });
}

+ (HTTPServer*) httpServer {
    return [self httpServerWithPort:8080];
}

+ (HTTPServer*) httpServerWithPort:(UInt16)port {
    NSString *webPath = [NSHomeDirectory() stringByAppendingPathComponent:@"/Documents/web"];
    NSString *resourcePath = [[[NSBundle bundleForClass:[self class]] resourcePath] stringByAppendingPathComponent:@"IGWebLogger.bundle"];
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSError *error = nil;
    
    if ([fileManager fileExistsAtPath:webPath]) {
        [fileManager removeItemAtPath:webPath error:nil];
    }
    
    if (![fileManager copyItemAtPath:resourcePath toPath:webPath error:&error] && error) {
        fprintf(stderr, "Failed copying resource to web path.\n");
        fflush(stderr);
        return nil;
    }
    
    fprintf(stdout, "WebServer document path: %s\n", webPath.UTF8String);
    fflush(stdout);
    
    HTTPServer* httpServer = [[HTTPServer alloc] init];
    [httpServer setConnectionClass:[IGWebLoggerURLConnection class]];
    [httpServer setType:@"_http._tcp."];
    [httpServer setPort:port];
    [httpServer setDocumentRoot:webPath];
    return httpServer;
}

#pragma mark - DDLogger

- (void)logMessage:(DDLogMessage *)logMessage {
	if ([self.webSockets count] > 0) {
        NSString *logMsg = [self formatLogMessage:logMessage];
        if (logMsg) {
            [self.webSockets enumerateObjectsUsingBlock:^(WebSocket* socket, NSUInteger idx, BOOL *stop) {
                [socket sendMessage:logMsg];
            }];
        }
	}
}

- (NSString *)loggerName {
	return @"hk.ignition.logger.IGWebLogger";
}

// a DDLogFormatter that format the log in JSON

#pragma mark - DDLogFormatter

- (NSString *)formatLogMessage:(DDLogMessage *)logMessage {
    NSString* logLevel = @"verbose";
    switch (logMessage.flag) {
        case DDLogFlagError : logLevel = @"error"; break;
        case DDLogFlagWarning : logLevel = @"warn"; break;
        case DDLogFlagInfo : logLevel = @"info"; break;
        default : logLevel = @"verbose"; break;
    }
    
    NSError* error;
    NSString* message = logMessage.message ? logMessage.message : @"";
    NSString* file = logMessage.file;
    NSString* function = logMessage.function ? logMessage.function : @"";
    NSDictionary* data = @{@"message": message,
                           @"level": logLevel,
                           @"file": file,
                           @"function": function,
                           @"line": @(logMessage.line)
                        };
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:data options:0 error:&error];
    NSString* jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return jsonStr;
}

@end
