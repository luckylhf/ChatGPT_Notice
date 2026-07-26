#import "StatusCore.h"

NSString *MLGMActivityLabel(MLGMActivityKind kind) {
    switch (kind) {
        case MLGMActivityReasoning: return @"推理";
        case MLGMActivityExecuting: return @"执行";
        case MLGMActivityGit: return @"Git";
        case MLGMActivityNetwork: return @"网络";
        case MLGMActivityReplying: return @"回复";
        case MLGMActivityWaiting: return @"等待确认";
        case MLGMActivityRetrying: return @"网络重试";
    }
}

NSDate *MLGMParseTimestamp(NSString *value) {
    static NSISO8601DateFormatter *fractional;
    static NSISO8601DateFormatter *plain;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fractional = [NSISO8601DateFormatter new];
        fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [NSISO8601DateFormatter new];
        plain.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [fractional dateFromString:value] ?: [plain dateFromString:value];
}

NSInteger MLGMElapsedSeconds(NSDate *eventDate, NSDate *now) {
    NSTimeInterval elapsed = [now timeIntervalSinceDate:eventDate];
    return MIN((NSInteger)9999, MAX((NSInteger)0, (NSInteger)floor(elapsed)));
}

@implementation MLGMStatusSignal
+ (instancetype)signal:(MLGMStatusSignalType)type taskID:(NSString *)taskID kind:(MLGMActivityKind)kind at:(NSDate *)date {
    MLGMStatusSignal *signal = [self new];
    signal.type = type;
    signal.taskID = taskID;
    signal.kind = kind;
    signal.date = date;
    return signal;
}
+ (instancetype)started:(NSString *)taskID kind:(MLGMActivityKind)kind at:(NSDate *)date {
    return [self signal:MLGMStatusSignalStarted taskID:taskID kind:kind at:date];
}
+ (instancetype)activity:(NSString *)taskID kind:(MLGMActivityKind)kind at:(NSDate *)date {
    return [self signal:MLGMStatusSignalActivity taskID:taskID kind:kind at:date];
}
+ (instancetype)finished:(NSString *)taskID at:(NSDate *)date {
    return [self signal:MLGMStatusSignalFinished taskID:taskID kind:MLGMActivityReasoning at:date];
}
@end

@implementation MLGMTaskStatus
@end

@interface MLGMStatusStore ()
@property(nonatomic) NSMutableDictionary<NSString *, MLGMTaskStatus *> *tasks;
@property(nonatomic) NSDictionary<NSString *, NSString *> *titles;
@end

@implementation MLGMStatusStore
- (instancetype)init {
    self = [super init];
    if (self) {
        _tasks = [NSMutableDictionary dictionary];
        _titles = @{};
    }
    return self;
}

- (void)setTitles:(NSDictionary<NSString *,NSString *> *)titles {
    _titles = [titles copy];
    [titles enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *title, BOOL *stop) {
        MLGMTaskStatus *task = self.tasks[key];
        if (task) task.title = title;
    }];
}

- (void)applySignal:(MLGMStatusSignal *)signal {
    NSString *resolvedID = [self resolvedID:signal.taskID];
    switch (signal.type) {
        case MLGMStatusSignalStarted: {
            if (!resolvedID) return;
            if (![signal.taskID hasPrefix:@"chat:"]) {
                [self.tasks removeObjectForKey:[@"chat:" stringByAppendingString:signal.taskID]];
            }
            MLGMTaskStatus *task = [MLGMTaskStatus new];
            task.taskID = resolvedID;
            task.kind = signal.kind;
            task.lastEventAt = signal.date;
            task.title = self.titles[resolvedID] ?: [self fallbackTitle:resolvedID];
            self.tasks[resolvedID] = task;
            break;
        }
        case MLGMStatusSignalActivity: {
            MLGMTaskStatus *task = resolvedID ? self.tasks[resolvedID] : self.sortedTasks.firstObject;
            if (!task) return;
            task.kind = signal.kind;
            task.lastEventAt = signal.date;
            break;
        }
        case MLGMStatusSignalFinished: {
            if (!signal.taskID) break;
            NSString *plainID = [signal.taskID hasPrefix:@"chat:"]
                ? [signal.taskID substringFromIndex:5]
                : signal.taskID;
            [self.tasks removeObjectForKey:plainID];
            [self.tasks removeObjectForKey:[@"chat:" stringByAppendingString:plainID]];
            break;
        }
    }
}

- (NSArray<MLGMTaskStatus *> *)sortedTasks {
    return [self.tasks.allValues sortedArrayUsingComparator:^NSComparisonResult(MLGMTaskStatus *a, MLGMTaskStatus *b) {
        NSComparisonResult dateOrder = [b.lastEventAt compare:a.lastEventAt];
        return dateOrder != NSOrderedSame ? dateOrder : [a.title localizedStandardCompare:b.title];
    }];
}

- (NSString *)resolvedID:(NSString *)taskID {
    if (!taskID) return nil;
    if ([taskID hasPrefix:@"chat:"]) {
        NSString *plain = [taskID substringFromIndex:5];
        if (self.tasks[plain] || self.titles[plain]) return plain;
    }
    return taskID;
}

- (NSString *)fallbackTitle:(NSString *)taskID {
    BOOL chat = [taskID hasPrefix:@"chat:"];
    NSString *value = chat ? [taskID substringFromIndex:5] : taskID;
    NSString *shortID = [value substringToIndex:MIN((NSUInteger)8, value.length)];
    return [NSString stringWithFormat:@"%@ %@", chat ? @"ChatGPT 会话" : @"Codex 任务", shortID];
}
@end

static NSString *MLGMArgumentText(id value) {
    if (!value) return @"";
    if ([value isKindOfClass:NSString.class]) return value;
    if ([NSJSONSerialization isValidJSONObject:value]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    }
    return [value description];
}

static BOOL MLGMContainsCommand(NSString *text, NSArray<NSString *> *tokens) {
    for (NSString *token in tokens) {
        NSString *escaped = [NSRegularExpression escapedPatternForString:token];
        NSString *pattern = [NSString stringWithFormat:@"(^|[^a-z0-9_-])%@(\\s|$)", escaped];
        if ([text rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static MLGMActivityKind MLGMClassifyTool(NSDictionary *payload, MLGMActivityKind current) {
    NSString *name = [payload[@"name"] isKindOfClass:NSString.class] ? [payload[@"name"] lowercaseString] : @"";
    NSString *namespace = [payload[@"namespace"] isKindOfClass:NSString.class] ? [payload[@"namespace"] lowercaseString] : @"";
    NSString *arguments = [MLGMArgumentText(payload[@"arguments"]) lowercaseString];
    NSString *combined = [NSString stringWithFormat:@"%@ %@ %@", namespace, name, arguments];

    if ([name isEqualToString:@"request_permissions"] || [combined containsString:@"request_permissions"]) {
        return MLGMActivityWaiting;
    }
    if ([name isEqualToString:@"wait"] || [name isEqualToString:@"write_stdin"] || [name isEqualToString:@"wait_agent"]) {
        if (current == MLGMActivityGit || current == MLGMActivityNetwork || current == MLGMActivityExecuting) return current;
        return MLGMActivityExecuting;
    }
    if (MLGMContainsCommand(combined, @[@"git", @"gh"])) return MLGMActivityGit;

    NSArray *networkPhrases = @[
        @"npm install", @"npm ci", @"pnpm install", @"yarn install",
        @"cargo fetch", @"brew install", @"pip install"
    ];
    BOOL phraseMatch = NO;
    for (NSString *phrase in networkPhrases) {
        if ([combined containsString:phrase]) {
            phraseMatch = YES;
            break;
        }
    }
    if ([namespace isEqualToString:@"web"]
        || [namespace containsString:@"codex_apps"]
        || [namespace containsString:@"browser"]
        || [combined containsString:@"web_search"]
        || [combined containsString:@"imagegen"]
        || MLGMContainsCommand(combined, @[@"curl", @"wget", @"ssh", @"scp", @"rsync"])
        || phraseMatch) {
        return MLGMActivityNetwork;
    }
    return MLGMActivityExecuting;
}

@interface MLGMSessionLogParser ()
@property(nonatomic, readwrite) NSString *sessionID;
@property(nonatomic) BOOL active;
@property(nonatomic) MLGMActivityKind currentKind;
@end

@implementation MLGMSessionLogParser
- (instancetype)initWithSessionID:(NSString *)sessionID {
    self = [super init];
    if (self) {
        _sessionID = [sessionID copy];
        _currentKind = MLGMActivityReasoning;
    }
    return self;
}

- (MLGMStatusSignal *)parseLine:(NSString *)line {
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![root isKindOfClass:NSDictionary.class]) return nil;
    NSDate *date = MLGMParseTimestamp(root[@"timestamp"]);
    if (!date) return nil;
    NSString *topType = root[@"type"] ?: @"";
    NSDictionary *payload = [root[@"payload"] isKindOfClass:NSDictionary.class] ? root[@"payload"] : @{};
    NSString *payloadType = payload[@"type"] ?: @"";

    if ([topType isEqualToString:@"event_msg"]) {
        if ([payloadType isEqualToString:@"task_started"]) {
            self.active = YES;
            self.currentKind = MLGMActivityReasoning;
            return [MLGMStatusSignal started:self.sessionID kind:MLGMActivityReasoning at:date];
        }
        if ([payloadType isEqualToString:@"task_complete"] || [payloadType isEqualToString:@"turn_aborted"]) {
            self.active = NO;
            return [MLGMStatusSignal finished:self.sessionID at:date];
        }
        if ([payloadType isEqualToString:@"agent_reasoning"]) return [self activity:MLGMActivityReasoning at:date];
        if ([payloadType isEqualToString:@"agent_message"]) return [self activity:MLGMActivityReplying at:date];
        if ([@[@"mcp_tool_call_end", @"web_search_end", @"patch_apply_end", @"image_generation_end"] containsObject:payloadType]) {
            return [self activity:MLGMActivityReasoning at:date];
        }
        return nil;
    }

    if (![topType isEqualToString:@"response_item"] || !self.active) return nil;
    if ([payloadType isEqualToString:@"reasoning"]) return [self activity:MLGMActivityReasoning at:date];
    if ([payloadType isEqualToString:@"message"] && [payload[@"role"] isEqualToString:@"assistant"]) {
        return [self activity:MLGMActivityReplying at:date];
    }
    if ([payloadType isEqualToString:@"web_search_call"]) return [self activity:MLGMActivityNetwork at:date];
    if ([@[@"function_call", @"custom_tool_call", @"tool_search_call"] containsObject:payloadType]) {
        return [self activity:MLGMClassifyTool(payload, self.currentKind) at:date];
    }
    if ([@[@"function_call_output", @"custom_tool_call_output", @"tool_search_output"] containsObject:payloadType]) {
        return [self activity:MLGMActivityReasoning at:date];
    }
    return nil;
}

- (MLGMStatusSignal *)activity:(MLGMActivityKind)kind at:(NSDate *)date {
    if (!self.active) return nil;
    self.currentKind = kind;
    return [MLGMStatusSignal activity:self.sessionID kind:kind at:date];
}
@end

@implementation MLGMDesktopLogParser
- (MLGMStatusSignal *)parseLine:(NSString *)line {
    NSRange firstSpace = [line rangeOfString:@" "];
    if (firstSpace.location == NSNotFound) return nil;
    NSDate *date = MLGMParseTimestamp([line substringToIndex:firstSpace.location]);
    if (!date) return nil;

    if ([line containsString:@"chatgpt_pubsub_reconnect_scheduled"]
        || [line rangeOfString:@"reconnectAttempt=[1-9][0-9]*" options:NSRegularExpressionSearch].location != NSNotFound
        || [line containsString:@"timed out"]
        || [line containsString:@"TimeoutError"]
        || [line containsString:@"ETIMEDOUT"]
        || [line containsString:@"timeout_error"]) {
        NSString *taskID = [self extractValue:@"conversationId" line:line];
        return [MLGMStatusSignal activity:taskID ? [@"chat:" stringByAppendingString:taskID] : nil
                                            kind:MLGMActivityRetrying
                                              at:date];
    }

    if ([line containsString:@"Reasoning summary turn-start config resolved"]) {
        NSString *taskID = [self extractValue:@"conversationId" line:line];
        if (taskID) return [MLGMStatusSignal started:[@"chat:" stringByAppendingString:taskID]
                                               kind:MLGMActivityReasoning
                                                 at:date];
    }
    if ([line containsString:@"Reasoning summary item completed"]) {
        NSString *taskID = [self extractValue:@"threadId" line:line];
        if (taskID) return [MLGMStatusSignal activity:[@"chat:" stringByAppendingString:taskID]
                                                kind:MLGMActivityReasoning
                                                  at:date];
    }
    if ([line containsString:@"Reasoning summary part added"]) {
        NSString *taskID = [self extractJSONValue:@"thread_id" line:line];
        if (taskID) return [MLGMStatusSignal activity:[@"chat:" stringByAppendingString:taskID]
                                                kind:MLGMActivityReasoning
                                                  at:date];
    }
    if ([line containsString:@"turn/completed"]
        || [line containsString:@"latestTurnStatus=completed"]
        || [line containsString:@"latestTurnStatus=interrupted"]) {
        NSString *taskID = [self extractValue:@"conversationId" line:line];
        if (taskID) return [MLGMStatusSignal finished:[@"chat:" stringByAppendingString:taskID] at:date];
    }
    return nil;
}

- (NSString *)extractValue:(NSString *)name line:(NSString *)line {
    NSString *needle = [name stringByAppendingString:@"="];
    NSRange range = [line rangeOfString:needle];
    if (range.location == NSNotFound) return nil;
    NSString *suffix = [line substringFromIndex:NSMaxRange(range)];
    NSRange whitespace = [suffix rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *value = whitespace.location == NSNotFound ? suffix : [suffix substringToIndex:whitespace.location];
    if (value.length == 0 || [@[@"null", @"none"] containsObject:value]) return nil;
    return value;
}

- (NSString *)extractJSONValue:(NSString *)name line:(NSString *)line {
    NSString *escaped = [NSRegularExpression escapedPatternForString:name];
    NSString *pattern = [NSString stringWithFormat:@"\\\"%@\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", escaped];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    return match.numberOfRanges > 1 ? [line substringWithRange:[match rangeAtIndex:1]] : nil;
}
@end
