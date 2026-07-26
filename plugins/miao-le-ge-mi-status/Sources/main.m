#import <Cocoa/Cocoa.h>
#import "StatusCore.h"

static NSString *const MLGMChatGPTBundleID = @"com.openai.codex";

@interface MLGMLogCursor : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic) unsigned long long offset;
@property(nonatomic, copy) NSString *pending;
- (instancetype)initWithPath:(NSString *)path;
- (NSArray<NSString *> *)readAvailableLines;
@end

@implementation MLGMLogCursor
- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
        _pending = @"";
    }
    return self;
}

- (NSArray<NSString *> *)readAvailableLines {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (size < self.offset) {
        self.offset = 0;
        self.pending = @"";
    }
    if (size == self.offset) return @[];

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:self.path];
    if (!handle) return @[];
    [handle seekToFileOffset:self.offset];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    self.offset += data.length;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return @[];
    NSString *combined = [self.pending stringByAppendingString:text];
    NSMutableArray<NSString *> *parts = [[combined componentsSeparatedByString:@"\n"] mutableCopy];
    if ([combined hasSuffix:@"\n"]) {
        self.pending = @"";
        if (parts.lastObject.length == 0) [parts removeLastObject];
    } else {
        self.pending = parts.lastObject ?: @"";
        if (parts.count > 0) [parts removeLastObject];
    }
    return parts;
}
@end

@interface MLGMSessionCursor : MLGMLogCursor
@property(nonatomic) MLGMSessionLogParser *parser;
@end
@implementation MLGMSessionCursor
@end

@interface MLGMLogMonitor : NSObject
@property(nonatomic, copy) void (^updateHandler)(NSArray<MLGMTaskStatus *> *);
- (void)start;
- (void)stop;
@end

@interface MLGMLogMonitor ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t timer;
@property(nonatomic) MLGMStatusStore *store;
@property(nonatomic) NSMutableDictionary<NSString *, MLGMSessionCursor *> *sessionCursors;
@property(nonatomic) MLGMLogCursor *desktopCursor;
@property(nonatomic) MLGMDesktopLogParser *desktopParser;
@property(nonatomic) NSDate *appLogStartedAt;
@property(nonatomic) NSInteger tick;
@property(nonatomic) NSInteger missingAppTicks;
@end

@implementation MLGMLogMonitor
- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("local.miao-le-ge-mi-status.monitor", DISPATCH_QUEUE_SERIAL);
        _store = [MLGMStatusStore new];
        _sessionCursors = [NSMutableDictionary dictionary];
        _desktopParser = [MLGMDesktopLogParser new];
    }
    return self;
}

- (void)start {
    dispatch_async(self.queue, ^{
        [self loadTitles];
        [self discoverDesktopLog];
        [self discoverSessions];
        [self consumeLogs];
        [self publish];

        self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC, NSEC_PER_MSEC * 100);
        dispatch_source_set_event_handler(self.timer, ^{
            [self scan];
        });
        dispatch_resume(self.timer);
    });
}

- (void)stop {
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
}

- (void)scan {
    self.tick++;
    if (self.tick % 5 == 0) {
        [self loadTitles];
        [self discoverDesktopLog];
        [self discoverSessions];
    }
    BOOL changed = [self consumeLogs];
    if (changed) [self publish];

    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:MLGMChatGPTBundleID].count == 0) {
        self.missingAppTicks++;
        if (self.missingAppTicks >= 3) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp terminate:nil];
            });
        }
    } else {
        self.missingAppTicks = 0;
    }
}

- (void)loadTitles {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".codex/session_index.jsonl"];
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!contents) return;
    NSMutableDictionary<NSString *, NSString *> *titles = [NSMutableDictionary dictionary];
    [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *item = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *taskID = [item[@"id"] isKindOfClass:NSString.class] ? item[@"id"] : nil;
        NSString *title = [item[@"thread_name"] isKindOfClass:NSString.class] ? item[@"thread_name"] : nil;
        if (taskID.length && title.length) titles[taskID] = title;
    }];
    [self.store setTitles:titles];
}

- (void)discoverDesktopLog {
    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/com.openai.codex"];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:root];
    NSString *latestPath;
    NSDate *latestDate;
    for (NSString *relative in enumerator) {
        NSString *name = relative.lastPathComponent;
        if (![name hasSuffix:@".log"] || [name rangeOfString:@"-t0-"].location == NSNotFound) continue;
        NSString *path = [root stringByAppendingPathComponent:relative];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        NSDate *modified = attributes[NSFileModificationDate];
        if (!latestDate || [modified compare:latestDate] == NSOrderedDescending) {
            latestDate = modified;
            latestPath = path;
        }
    }
    if (!latestPath || [self.desktopCursor.path isEqualToString:latestPath]) return;

    self.desktopCursor = [[MLGMLogCursor alloc] initWithPath:latestPath];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:latestPath error:nil];
    self.appLogStartedAt = attributes[NSFileCreationDate] ?: latestDate ?: NSDate.date;
}

- (void)discoverSessions {
    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@".codex/sessions"];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:root];
    NSDate *cutoff = [self.appLogStartedAt dateByAddingTimeInterval:-5] ?: [NSDate dateWithTimeIntervalSinceNow:-86400];
    for (NSString *relative in enumerator) {
        if (![relative hasSuffix:@".jsonl"]) continue;
        NSString *path = [root stringByAppendingPathComponent:relative];
        if (self.sessionCursors[path]) continue;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        NSDate *modified = attributes[NSFileModificationDate];
        if (!modified || [modified compare:cutoff] == NSOrderedAscending) continue;
        NSString *sessionID = [self sessionIDFromPath:path];
        if (!sessionID) continue;

        MLGMSessionCursor *cursor = [[MLGMSessionCursor alloc] initWithPath:path];
        cursor.parser = [[MLGMSessionLogParser alloc] initWithSessionID:sessionID];
        self.sessionCursors[path] = cursor;
    }
}

- (NSString *)sessionIDFromPath:(NSString *)path {
    NSString *pattern = @"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\.jsonl$";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:path options:0 range:NSMakeRange(0, path.length)];
    return match.numberOfRanges > 1 ? [path substringWithRange:[match rangeAtIndex:1]] : nil;
}

- (BOOL)consumeLogs {
    NSMutableArray<MLGMStatusSignal *> *signals = [NSMutableArray array];
    for (NSString *line in [self.desktopCursor readAvailableLines]) {
        MLGMStatusSignal *signal = [self.desktopParser parseLine:line];
        if (signal) [signals addObject:signal];
    }
    for (MLGMSessionCursor *cursor in self.sessionCursors.allValues) {
        for (NSString *line in [cursor readAvailableLines]) {
            MLGMStatusSignal *signal = [cursor.parser parseLine:line];
            if (signal) [signals addObject:signal];
        }
    }
    [signals sortUsingComparator:^NSComparisonResult(MLGMStatusSignal *a, MLGMStatusSignal *b) {
        return [a.date compare:b.date];
    }];
    for (MLGMStatusSignal *signal in signals) {
        [self.store applySignal:signal];
    }
    return signals.count > 0;
}

- (void)publish {
    NSMutableArray<MLGMTaskStatus *> *snapshot = [NSMutableArray array];
    for (MLGMTaskStatus *task in self.store.sortedTasks) {
        MLGMTaskStatus *copy = [MLGMTaskStatus new];
        copy.taskID = task.taskID;
        copy.title = task.title;
        copy.kind = task.kind;
        copy.lastEventAt = task.lastEventAt;
        [snapshot addObject:copy];
    }
    if (!self.updateHandler) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.updateHandler(snapshot);
    });
}
@end

@interface MLGMAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) NSStatusItem *statusItem;
@property(nonatomic) NSMenu *statusMenu;
@property(nonatomic) MLGMLogMonitor *monitor;
@property(nonatomic) NSArray<MLGMTaskStatus *> *tasks;
@property(nonatomic) NSTimer *displayTimer;
@end

@implementation MLGMAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.tasks = @[];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"没有任务：0";
    self.statusItem.button.toolTip = @"没有任务：0";
    self.statusMenu = [NSMenu new];
    self.statusItem.menu = self.statusMenu;

    self.monitor = [MLGMLogMonitor new];
    __weak typeof(self) weakSelf = self;
    self.monitor.updateHandler = ^(NSArray<MLGMTaskStatus *> *tasks) {
        weakSelf.tasks = tasks;
        [weakSelf updateDisplay];
    };
    [self.monitor start];

    self.displayTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                         target:self
                                                       selector:@selector(updateDisplay)
                                                       userInfo:nil
                                                        repeats:YES];
    [self updateDisplay];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.monitor stop];
    [self.displayTimer invalidate];
}

- (void)updateDisplay {
    MLGMTaskStatus *recent = self.tasks.firstObject;
    if (!recent) {
        self.statusItem.button.title = @"没有任务：0";
        self.statusItem.button.toolTip = @"没有任务：0";
        [self updateMenuWithLines:@[@"没有任务：0"]];
        return;
    }

    NSDate *now = NSDate.date;
    NSInteger seconds = MLGMElapsedSeconds(recent.lastEventAt, now);
    self.statusItem.button.title = [NSString stringWithFormat:@"%@：%ld",
                                    MLGMActivityLabel(recent.kind), (long)seconds];

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (MLGMTaskStatus *task in self.tasks) {
        NSInteger taskSeconds = MLGMElapsedSeconds(task.lastEventAt, now);
        [lines addObject:[NSString stringWithFormat:@"%@：%ld · %@",
                          MLGMActivityLabel(task.kind), (long)taskSeconds, task.title]];
    }
    self.statusItem.button.toolTip = [lines componentsJoinedByString:@"\n"];
    [self updateMenuWithLines:lines];
}

- (void)updateMenuWithLines:(NSArray<NSString *> *)lines {
    [self.statusMenu removeAllItems];
    for (NSString *line in lines) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:line
                                                     action:@selector(menuItemSelected:)
                                              keyEquivalent:@""];
        item.target = self;
        [self.statusMenu addItem:item];
    }
}

- (void)menuItemSelected:(NSMenuItem *)item {
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        MLGMAppDelegate *delegate = [MLGMAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
