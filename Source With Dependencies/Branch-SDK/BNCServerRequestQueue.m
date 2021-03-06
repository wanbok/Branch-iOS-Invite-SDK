//
//  BNCServerRequestQueue.m
//  Branch-SDK
//
//  Created by Qinwei Gong on 9/6/14.
//
//

#import "BNCServerRequestQueue.h"
#import "BNCPreferenceHelper.h"
#import "BranchCloseRequest.h"
#import "BranchOpenRequest.h"

NSString * const BRANCH_QUEUE_FILE = @"BNCServerRequestQueue";
NSUInteger const BATCH_WRITE_TIMEOUT = 3;

@interface BNCServerRequestQueue()

@property (nonatomic, strong) NSMutableArray *queue;
@property (nonatomic) dispatch_queue_t asyncQueue;
@property (strong, nonatomic) NSTimer *writeTimer;

@end


@implementation BNCServerRequestQueue

- (id)init {
    if (self = [super init]) {
        self.queue = [NSMutableArray array];
        self.asyncQueue = dispatch_queue_create("brnch_persist_queue", NULL);
    }
    return self;
}

- (void)enqueue:(BNCServerRequest *)request {
    @synchronized(self.queue) {
        if (request) {
            [self.queue addObject:request];
            [self persistEventually];
        }
    }
}

- (void)insert:(BNCServerRequest *)request at:(unsigned int)index {
    @synchronized(self.queue) {
        if (index > self.queue.count) {
            [[BNCPreferenceHelper preferenceHelper] log:FILE_NAME line:LINE_NUM message:@"Invalid queue operation: index out of bound!"];
            return;
        }
        
        if (request) {
            [self.queue insertObject:request atIndex:index];
            [self persistEventually];
        }
    }
}

- (BNCServerRequest *)dequeue {
    BNCServerRequest *request = nil;
    
    @synchronized(self.queue) {
        if (self.queue.count > 0) {
            request = [self.queue objectAtIndex:0];
            [self.queue removeObjectAtIndex:0];
            [self persistEventually];
        }
    }
    
    return request;
}

- (BNCServerRequest *)removeAt:(unsigned int)index {
    BNCServerRequest *request = nil;
    @synchronized(self.queue) {
        if (index >= self.queue.count) {
            [[BNCPreferenceHelper preferenceHelper] log:FILE_NAME line:LINE_NUM message:@"Invalid queue operation: index out of bound!"];
            return nil;
        }
        
        request = [self.queue objectAtIndex:index];
        [self.queue removeObjectAtIndex:index];
        [self persistEventually];
    }
    
    return request;
}

- (void)remove:(BNCServerRequest *)request {
    [self.queue removeObject:request];
    [self persistEventually];
}

- (BNCServerRequest *)peek {
    return [self peekAt:0];
}

- (BNCServerRequest *)peekAt:(unsigned int)index {
    if (index >= self.queue.count) {
        [[BNCPreferenceHelper preferenceHelper] log:FILE_NAME line:LINE_NUM message:@"Invalid queue operation: index out of bound!"];
        return nil;
    }
    
    BNCServerRequest *request = nil;
    request = [self.queue objectAtIndex:index];
    
    return request;
}

- (unsigned int)size {
    return (unsigned int)self.queue.count;
}

- (NSString *)description {
    return [self.queue description];
}

- (void)clearQueue {
    [self.queue removeAllObjects];
    [self persistEventually];
}

- (BOOL)containsInstallOrOpen {
    for (int i = 0; i < self.queue.count; i++) {
        BNCServerRequest *req = [self.queue objectAtIndex:i];
        // Install extends open, so only need to check open.
        if ([req isKindOfClass:[BranchOpenRequest class]]) {
            return YES;
        }
    }
    return NO;
}

- (BranchOpenRequest *)moveInstallOrOpenToFront:(NSInteger)networkCount {
    BOOL requestAlreadyInProgress = networkCount > 0;

    BNCServerRequest *openOrInstallRequest;
    for (int i = 0; i < self.queue.count; i++) {
        BNCServerRequest *req = [self.queue objectAtIndex:i];
        if ([req isKindOfClass:[BranchOpenRequest class]]) {
            
            // Already in front, nothing to do
            if (i == 0 || (i == 1 && requestAlreadyInProgress)) {
                return (BranchOpenRequest *)req;
            }

            // Otherwise, pull this request out and stop early
            openOrInstallRequest = [self removeAt:i];
            break;
        }
    }
    
    if (!openOrInstallRequest) {
        NSLog(@"[Branch Warning] No install or open request in queue while trying to move it to the front");
        return nil;
    }
    
    if (!requestAlreadyInProgress || !self.queue.count) {
        [self insert:openOrInstallRequest at:0];
    }
    else {
        [self insert:openOrInstallRequest at:1];
    }
    
    return (BranchOpenRequest *)openOrInstallRequest;
}

- (BOOL)containsClose {
    for (int i = 0; i < self.queue.count; i++) {
        BNCServerRequest *req = [self.queue objectAtIndex:i];
        if ([req isKindOfClass:[BranchCloseRequest class]]) {
            return YES;
        }
    }

    return NO;
}


#pragma mark - Private method

- (void)persistEventually {
    if (!self.writeTimer.valid) {
        self.writeTimer = [NSTimer scheduledTimerWithTimeInterval:BATCH_WRITE_TIMEOUT target:self selector:@selector(persistToDisk) userInfo:nil repeats:NO];
    }
}

- (void)persistImmediately {
    [self.writeTimer invalidate];
    
    [self persistToDisk];
}

- (void)persistToDisk {
    NSArray *requestsToPersist = [self.queue copy];
    dispatch_async(self.asyncQueue, ^{
        NSMutableArray *encodedRequests = [[NSMutableArray alloc] init];
        
        for (BNCServerRequest *req in requestsToPersist) {
            NSData *encodedReq = [NSKeyedArchiver archivedDataWithRootObject:req];
            [encodedRequests addObject:encodedReq];
        }
        
        if (![NSKeyedArchiver archiveRootObject:encodedRequests toFile:[self queueFile]]) {
            NSLog(@"[Branch Warning] Failed to persist queue to disk");
        }
    });
}

- (void)retrieve {
    NSMutableArray *queue = [[NSMutableArray alloc] init];
    NSArray *encodedRequests = [NSKeyedUnarchiver unarchiveObjectWithFile:[self queueFile]];

    for (NSData *encodedRequest in encodedRequests) {
        BNCServerRequest *request = [NSKeyedUnarchiver unarchiveObjectWithData:encodedRequest];
        
        // Throw out persisted close requests
        if (![request isKindOfClass:[BranchCloseRequest class]]) {
            [queue addObject:request];
        }
    }
    
    self.queue = queue;
}

- (NSString *)queueFile {
    return [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:BRANCH_QUEUE_FILE];
}

#pragma mark - Singleton method

+ (id)getInstance {
    static BNCServerRequestQueue *sharedQueue = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        sharedQueue = [[BNCServerRequestQueue alloc] init];
        [sharedQueue retrieve];
        [[BNCPreferenceHelper preferenceHelper] log:FILE_NAME line:LINE_NUM message:@"Retrieved from Persist: %@", sharedQueue];
    });
    
    return sharedQueue;
}

@end
