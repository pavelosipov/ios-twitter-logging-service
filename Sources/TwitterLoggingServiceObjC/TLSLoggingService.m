//
//  TLSLoggingService.m
//  TwitterLoggingService
//
//  Created on 12/11/13.
//  Copyright (c) 2016 Twitter, Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//          http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

#import <pthread.h>
#import "TLSLoggingService+Advanced.h"
#import "TLSProtocols.h"
#import "TLS_Project.h"

@class TLSLoggingService;

#define TLSCANLOGMODE_ALWAYS        (0)
#define TLSCANLOGMODE_CHECKCACHED   (1)
#define TLSCANLOGMODE_CHECKFULL     (2)

#ifndef TLSCANLOGMODE
#define TLSCANLOGMODE TLSCANLOGMODE_CHECKCACHED
#endif

// Singleton Reference
static TLSLoggingService *sLoggingService;

#if DEBUG
#define SANITIZED_LEVEL(level) (level)
#else
#define SANITIZED_LEVEL(level) ((level) & ~TLSLogLevelMaskDebug)
#endif

static NSString * const kMainThreadName = @"Main";

@interface TLSLoggingService ()
{
    dispatch_queue_t _transactionQueue;
    dispatch_queue_t _loggingQueue;
    CFAbsoluteTime _baseTimestamp;
    NSMutableSet<id<TLSOutputStream>> *_streamsM;

#if TLSCANLOGMODE == TLSCANLOGMODE_CHECKCACHED
    dispatch_queue_t _quickFilterQueue;
    TLSLogLevelMask _quickFilterLevels;
    NSMutableSet<NSString *> *_quickFilterOffChannelsM;
    NSUInteger _quickFilterOutputStreamCount;
#endif
}

@property (nonatomic, readwrite) NSUInteger maximumSafeMessageLength;
@property (atomic, readwrite, nullable, weak) id<TLSLoggingServiceDelegate> delegate;

// accessible from external queues

- (void)_logDispatchWithLevel:(TLSLogLevel)level
                      channel:(NSString *)channel
                         file:(NSString *)file
                     function:(NSString *)function
                         line:(NSInteger)line
                      context:(id)contextObject
                      options:(TLSLogMessageOptions)options
                       format:(NSString *)format
                    arguments:(va_list)arguments TLS_OBJC_DIRECT;
- (BOOL)_canLogWithLevel:(TLSLogLevel)level
                 channel:(NSString *)channel
                 context:(id)contextObject TLS_OBJC_DIRECT;

// accessible from any queue except the quickFilter queue

- (void)_nonquickFilter_resetQuickFilter:(NSUInteger)outputStreamCount TLS_OBJC_DIRECT;

// accessible from transaction queue

- (void)_transaction_logExecuteWithTimestamp:(CFAbsoluteTime)timestamp
                                       level:(TLSLogLevel)level
                                     channel:(NSString *)channel
                                        file:(NSString *)file
                                    function:(NSString *)function
                                        line:(NSInteger)line
                                     context:(id)contextObject
                                    threadId:(unsigned int)threadId
                                  threadName:(NSString *)threadName
                                     message:(NSString *)message TLS_OBJC_DIRECT;
- (TLSFilterStatus)_transaction_filterLogStream:(id<TLSOutputStream>)stream
                                          level:(TLSLogLevel)level
                                        channel:(NSString *)channel
                                        context:(id)contextObject TLS_OBJC_DIRECT;

@end

@implementation TLSLoggingService

+ (instancetype)sharedInstance
{
    static dispatch_once_t sOnceToken;
    dispatch_once(&sOnceToken, ^{
        sLoggingService = [[TLSLoggingService alloc] init];
    });
    return sLoggingService;
}

- (instancetype)init
{
    if (self = [super init]) {
        _baseTimestamp = CFAbsoluteTimeGetCurrent();
        _streamsM = [[NSMutableSet alloc] init];
        _loggingQueue = dispatch_queue_create("TLSLoggingService.logging", DISPATCH_QUEUE_SERIAL);
        _transactionQueue = dispatch_queue_create("TLSLoggingService.transaction", DISPATCH_QUEUE_SERIAL);
        _maximumSafeMessageLength = 0;

#if TLSCANLOGMODE == TLSCANLOGMODE_CHECKCACHED
        _quickFilterQueue = dispatch_queue_create("TLSLoggingService.quickFilter", DISPATCH_QUEUE_SERIAL);
        _quickFilterLevels = SANITIZED_LEVEL(TLSLogLevelMaskAll);
        _quickFilterOutputStreamCount = 0;
        _quickFilterOffChannelsM = [[NSMutableSet alloc] init];
#endif
    }
    return self;
}

- (void)dealloc
{
    [self flush];
}

- (void)addOutputStream:(id<TLSOutputStream>)stream
{
    if (!stream) {
        return;
    }

    [self dispatchAsynchronousTransaction:^{
        [self->_streamsM addObject:stream];
        [self _nonquickFilter_resetQuickFilter:self->_streamsM.count];
    }];
}

- (void)logWithLevel:(TLSLogLevel)level
             channel:(NSString *)channel
                file:(NSString *)file
            function:(NSString *)function
                line:(NSInteger)line
       contextObject:(id)contextObject
             options:(TLSLogMessageOptions)options
             message:(NSString *)message, ...
{
    va_list arguments;
    va_start(arguments, message);
    [self _logDispatchWithLevel:level
                        channel:channel
                           file:file
                       function:function
                           line:line
                        context:contextObject
                        options:options
                         format:message
                      arguments:arguments];
    va_end(arguments);
}

#pragma mark Private

- (void)_nonquickFilter_resetQuickFilter:(NSUInteger)outputStreamCount
{
#if TLSCANLOGMODE == TLSCANLOGMODE_CHECKCACHED
    @autoreleasepool {
        dispatch_sync(_quickFilterQueue, ^{
            self->_quickFilterLevels = SANITIZED_LEVEL(TLSLogLevelMaskAll);
            [self->_quickFilterOffChannelsM removeAllObjects];
            self->_quickFilterOutputStreamCount = outputStreamCount;
        });
    }
#endif
}

- (void)_logDispatchWithLevel:(TLSLogLevel)level
                      channel:(NSString *)channel
                         file:(NSString *)file
                     function:(NSString *)function
                         line:(NSInteger)line
                      context:(id)contextObject
                      options:(TLSLogMessageOptions)options
                       format:(NSString *)format
                    arguments:(va_list)arguments
{
    if (channel && format) {
        const mach_port_t threadId = pthread_mach_thread_np(pthread_self());
        NSString * const threadName = TLSCurrentThreadName();
        const CFAbsoluteTime timestamp = CFAbsoluteTimeGetCurrent();
        NSString * message = [[NSString alloc] initWithFormat:format arguments:arguments];

        if (TLS_BITMASK_EXCLUDES_FLAGS(options, TLSLogMessageOptionsIgnoringMaximumSafeMessageLength)) {
            const NSUInteger maximumMessageLength = self.maximumSafeMessageLength;
            if (maximumMessageLength > 0) {
                const NSUInteger length = message.length;
                if (length > maximumMessageLength) {
                    NSUInteger lengthToLog = maximumMessageLength;

                    const id<TLSLoggingServiceDelegate> delegate = self.delegate;
                    if ([delegate respondsToSelector:@selector(tls_loggingService:lengthToLogForMessageExceedingMaxSafeLength:level:channel:file:function:line:contextObject:message:)]) {
                        lengthToLog = [delegate tls_loggingService:self
                       lengthToLogForMessageExceedingMaxSafeLength:maximumMessageLength
                                                             level:level
                                                           channel:channel
                                                              file:file
                                                          function:function
                                                              line:line
                                                     contextObject:contextObject
                                                           message:message];
                    }

                    if (!lengthToLog) {
                        return;
                    } else if (lengthToLog < length) {
                        message = [message substringToIndex:lengthToLog];
                    }
                }
            }
        }

        [self dispatchAsynchronousTransaction:^{
            [self _transaction_logExecuteWithTimestamp:timestamp
                                                 level:level
                                               channel:channel
                                                  file:file
                                              function:function
                                                  line:line
                                               context:contextObject
                                              threadId:threadId
                                            threadName:threadName
                                               message:message];
        }];
    }
}

- (void)_transaction_logExecuteWithTimestamp:(CFAbsoluteTime)timestamp
                                       level:(TLSLogLevel)level
                                     channel:(NSString *)channel
                                        file:(NSString *)file
                                    function:(NSString *)function
                                        line:(NSInteger)line
                                     context:(id)contextObject
                                    threadId:(unsigned int)threadId
                                  threadName:(NSString *)threadName
                                     message:(NSString *)message
{
    if (_streamsM.count > 0) {
        const NSTimeInterval elapsedTime = timestamp - _baseTimestamp;
        TLSLogMessageInfo *info = [[TLSLogMessageInfo alloc] initWithLevel:level
                                                                      file:file
                                                                  function:function
                                                                      line:line
                                                                   channel:channel
                                                                 timestamp:[NSDate dateWithTimeIntervalSinceReferenceDate:timestamp]
                                                               logLifespan:elapsedTime
                                                                  threadId:threadId
                                                                threadName:threadName
                                                             contextObject:contextObject
                                                                   message:message];
        NSMutableSet *permittedStreams = [[NSMutableSet alloc] init];
        struct {
            unsigned int channel:1;
            unsigned int level:1;
            unsigned int streamEncountered:1;
        } exclusiveFiltering;
        exclusiveFiltering.channel = exclusiveFiltering.level = 1;
        exclusiveFiltering.streamEncountered = 0;
        for (id<TLSOutputStream> stream in _streamsM) {
            const TLSFilterStatus status = [self _transaction_filterLogStream:stream
                                                                        level:level
                                                                      channel:channel
                                                                      context:contextObject];
            if (TLSFilterStatusOK == status) {
                [permittedStreams addObject:stream];
            }
            if (exclusiveFiltering.channel && TLS_BITMASK_EXCLUDES_FLAGS(status, TLSFilterStatusCannotLogChannel)) {
                exclusiveFiltering.channel = 0;
            }
            if (exclusiveFiltering.level && TLS_BITMASK_EXCLUDES_FLAGS(status, TLSFilterStatusCannotLogLevel)) {
                exclusiveFiltering.level = 0;
            }
            exclusiveFiltering.streamEncountered = 1;
        }
        if (permittedStreams.count > 0) {
            dispatch_async(_loggingQueue, ^{
                @autoreleasepool {
                    for (id<TLSOutputStream> stream in permittedStreams) {
                        [stream tls_outputLogInfo:info];
                    }
                }
            });
        }
#if TLSCANLOGMODE == TLSCANLOGMODE_CHECKCACHED
        else if (exclusiveFiltering.streamEncountered && (exclusiveFiltering.channel || exclusiveFiltering.level)) {
            @autoreleasepool {
                dispatch_sync(_quickFilterQueue, ^{
                    if (exclusiveFiltering.channel) {
                        [self->_quickFilterOffChannelsM addObject:channel];
                    }
                    if (exclusiveFiltering.level) {
                        self->_quickFilterLevels &= ~(1 << level);
                    }
                });
            }
        }
#endif
    }
}

- (TLSFilterStatus)_transaction_filterLogStream:(id<TLSOutputStream>)stream
                                          level:(TLSLogLevel)level
                                        channel:(NSString *)channel
                                        context:(id)contextObject
{
    const TLSLogLevelMask mask = SANITIZED_LEVEL(TLSLogLevelMaskAll);

    // Can we log to this level?
    if (TLS_BITMASK_EXCLUDES_FLAGS(mask, (1 << level))) {
        return TLSFilterStatusCannotLogLevel;
    }

    if ([stream respondsToSelector:@selector(tls_shouldFilterLevel:channel:contextObject:)]) {
        return [stream tls_shouldFilterLevel:level
                                     channel:channel
                               contextObject:contextObject];
    }

    return TLSFilterStatusOK;
}

- (BOOL)_canLogWithLevel:(TLSLogLevel)level
                 channel:(NSString *)channel
                 context:(id)contextObject
{
#if TLSCANLOGMODE == TLSCANLOGMODE_CHECKCACHED

    __block BOOL canLog = (nil != channel);
    if (canLog) {
        @autoreleasepool {
            dispatch_sync(_quickFilterQueue, ^{
                canLog =    (self->_quickFilterOutputStreamCount > 0)
                         && TLS_BITMASK_HAS_SUBSET_FLAGS(self->_quickFilterLevels, (1 << level))
                         && ![self->_quickFilterOffChannelsM containsObject:channel];
            });
        }
    }
    return canLog;

#elif TLSCANLOGMODE == TLSCANLOGMODE_CHECKFULL

    __block BOOL canLog = NO;
    [self dispatchSynchronousTransaction:^{
        for (id<TLSOutputStream> stream in self->_streamsM) {
            TLSFilterStatus status = [self _transaction_filterLogStream:stream
                                                                  level:level
                                                                channel:channel
                                                                context:contextObject];
            if (TLSFilterStatusOK == status) {
                canLog = YES;
                break;
            }
        }
    }];
    return canLog;

#else // TLSCANLOGMODE == TLSCANLOGMODE_ALWAYS

#if DEBUG
    return (level <= TLSLogLevelDebug);
#else
    return (level < TLSLogLevelDebug);
#endif

#endif
}

@end

@implementation TLSLoggingService (Advanced)

- (NSDate *)startupTimestamp
{
    return [NSDate dateWithTimeIntervalSinceReferenceDate:_baseTimestamp];
}

// see `@implementation TLSLoggingService` for `- (void)addOutputStream:(id<TLSOutputStream>)stream`

- (void)removeOutputStream:(id<TLSOutputStream>)stream
{
    if (!stream) {
        return;
    }

    [self dispatchAsynchronousTransaction:^{
        if ([self->_streamsM containsObject:stream]) {
            [self->_streamsM removeObject:stream];

            [self _nonquickFilter_resetQuickFilter:self->_streamsM.count];

            dispatch_async(self->_loggingQueue, ^{
                @autoreleasepool {
                    if ([stream respondsToSelector:@selector(tls_flush)]) {
                        [stream tls_flush];
                    }
                }
            });
        }
    }];
}

- (NSSet *)outputStreams
{
    __block NSSet *streams;
    [self dispatchSynchronousTransaction:^{
        streams = [self->_streamsM copy];
    }];
    return streams;
}

- (void)updateOutputStream:(id<TLSOutputStream>)stream
{
    if (!stream) {
        return;
    }

#if TLSCANLOGMODE == TLSCANLOGMODE_CHECKCACHED
    dispatch_block_t block = ^{
        if ([self->_streamsM containsObject:stream]) {
            [self _nonquickFilter_resetQuickFilter:self->_streamsM.count];
        }
    };

    [self dispatchAsynchronousTransaction:block];
#endif
}

- (void)dispatchSynchronousTransaction:(dispatch_block_t NS_NOESCAPE)block
{
    @autoreleasepool {
        dispatch_sync(_transactionQueue, block);
    }
}

- (void)dispatchAsynchronousTransaction:(dispatch_block_t)block
{
    dispatch_async(_transactionQueue, ^{
        @autoreleasepool {
            block();
        }
    });
}

- (void)flush
{
    // get all log message transactions onto the logging queue
    // and get our output streams from the transaction queue
    __block NSSet *streams = nil;
    [self dispatchSynchronousTransaction:^{
        streams = [self->_streamsM copy];
    }];

    // get all log messages off the logging queue and then flush all output streams
    @autoreleasepool {
        dispatch_sync(_loggingQueue, ^{
            for (id<TLSOutputStream> stream in streams) {
                if ([stream respondsToSelector:@selector(tls_flush)]) {
                    [stream tls_flush];
                }
            }
        });
    }

    /*

     NOTE:

     We do not do the following:

     dispatch_sync(_transactionQueue, ^{
         dispatch_sync(_loggingQueue, ^{
             for (id<TLSOutputStream> stream in _streamsM) {
                 if ([stream respondsToSelector:@selector(tls_flush)]) {
                        [stream tls_flush];
                    }
                 }
             });
         });
     });

     This would expose the potential for a deadlock if any queued logging statements would lead to a
     log message OR if any output stream's tls_flush method would lead to a log message.

     By "flushing" the transaction queue first we don't have to block that queue with the completion
     of the logging queue.  The only place where we expose a synchronous block executing code
     outside TLSLoggingService on the transaction queue is with the TLSFiltering method
     implementations which MUST NOT do anything that interacts with the TLSLoggingService.

     */
}

- (NSSet<id<TLSOutputStream, TLSDataRetrieval>> *)outputStreamsThatSupportLoggedDataRetrieval
{
    NSSet *streams = self.outputStreams;

    NSMutableSet<id<TLSOutputStream, TLSDataRetrieval>> *dataRetrievalStream = [[NSMutableSet alloc] init];
    for (id<TLSOutputStream> stream in streams) {
        if ([stream conformsToProtocol:@protocol(TLSDataRetrieval)]) {
            [dataRetrievalStream addObject:(id<TLSOutputStream, TLSDataRetrieval>)stream];
        }
    }

    return [dataRetrievalStream copy];
}

- (NSData *)retrieveLoggedDataFromOutputStream:(id<TLSOutputStream, TLSDataRetrieval>)stream
                                      maxBytes:(NSUInteger)maxBytes
{
    if (![stream conformsToProtocol:@protocol(TLSDataRetrieval)]) {
        return nil;
    }

    __block NSData *data;
    @autoreleasepool {
        dispatch_sync(_loggingQueue, ^{
            data = [stream tls_retrieveLoggedData:maxBytes];
        });
    }
    return data;
}

@end

void TLSvaLog(TLSLoggingService *service,
              TLSLogLevel level,
              NSString *channel,
              NSString *file,
              NSString *function,
              NSInteger line,
              id contextObject,
              TLSLogMessageOptions options,
              NSString *format,
              va_list arguments)
{
    [(service ?: sLoggingService) _logDispatchWithLevel:level
                                                channel:channel
                                                   file:file
                                               function:function
                                                   line:line
                                                context:contextObject
                                                options:options
                                                 format:format
                                              arguments:arguments];
}

void TLSLogEx(TLSLoggingService *service,
              TLSLogLevel level,
              NSString *channel,
              NSString *file,
              NSString *function,
              NSInteger line,
              id contextObject,
              TLSLogMessageOptions options,
              NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    TLSvaLog(service,
             level,
             channel,
             file,
             function,
             line,
             contextObject,
             options,
             format,
             arguments);
    va_end(arguments);
}

void TLSLogString(TLSLoggingService *service,
                  TLSLogLevel level,
                  NSString *channel,
                  NSString *file,
                  NSString *function,
                  NSInteger line,
                  id contextObject,
                  TLSLogMessageOptions options,
                  NSString *message)
{
    TLSLogEx(service,
             level,
             channel,
             file,
             function,
             line,
             contextObject,
             options,
             @"%@",
             message);
}

BOOL TLSCanLog(TLSLoggingService *service,
               TLSLogLevel level,
               NSString *channel,
               id contextObject)
{
    return [(service ?: sLoggingService) _canLogWithLevel:level
                                                  channel:channel
                                                  context:contextObject];
}

NSString *TLSCurrentThreadName()
{
    if ([NSThread isMainThread]) {
        return kMainThreadName;
    }

    NSString *name = nil;
    name = [NSThread currentThread].name;
    if (name.length > 0) {
        return name;
    }

    const char *nameCStr = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    if (nameCStr) {
        name = @(nameCStr);
        if (name.length > 0) {
            return name;
        }
    }

    do
    {
        const size_t nameLen = NAME_MAX + 1;
        char buffer[nameLen];
        if (0 == pthread_getname_np(pthread_self(), buffer, nameLen)) {
            name = @(buffer);
            if (name.length > 0) {
                return name;
            }
        }
    } while (0);

    return nil;
}
