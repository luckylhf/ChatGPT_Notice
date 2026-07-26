#import <Foundation/Foundation.h>
#import "StatusCore.h"

static NSInteger failures = 0;

#define CHECK(condition, message) do { \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL: %s\n", message); \
    } \
} while (0)

static NSString *JSONLine(NSString *timestamp, NSString *topType, NSDictionary *payload) {
    NSDictionary *root = @{@"timestamp": timestamp, @"type": topType, @"payload": payload};
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *FunctionCall(NSString *timestamp, NSString *name, NSString *arguments) {
    return JSONLine(timestamp, @"response_item", @{
        @"type": @"function_call",
        @"name": name,
        @"arguments": arguments,
    });
}

int main(void) {
    @autoreleasepool {
        MLGMSessionLogParser *session = [[MLGMSessionLogParser alloc] initWithSessionID:@"thread-1"];
        MLGMStatusSignal *start = [session parseLine:JSONLine(
            @"2026-07-23T10:00:00.000Z", @"event_msg", @{@"type": @"task_started"}
        )];
        CHECK(start.type == MLGMStatusSignalStarted, "task_started should start a task");
        CHECK(start.kind == MLGMActivityReasoning, "task should start in reasoning");

        MLGMStatusSignal *heartbeat = [session parseLine:JSONLine(
            @"2026-07-23T10:03:30.000Z", @"response_item", @{@"type": @"reasoning"}
        )];
        CHECK(heartbeat.type == MLGMStatusSignalActivity, "reasoning should be an activity heartbeat");
        CHECK([heartbeat.date isEqualToDate:MLGMParseTimestamp(@"2026-07-23T10:03:30.000Z")],
              "heartbeat should carry its own timestamp");

        MLGMStatusSignal *git = [session parseLine:FunctionCall(
            @"2026-07-23T10:03:31.000Z", @"exec_command", @"{\"cmd\":\"git push origin main\"}"
        )];
        CHECK(git.kind == MLGMActivityGit, "git commands should be Git");

        MLGMStatusSignal *wait = [session parseLine:FunctionCall(
            @"2026-07-23T10:03:32.000Z", @"wait", @"{\"cell_id\":\"1\"}"
        )];
        CHECK(wait.kind == MLGMActivityGit, "wait should preserve the active Git category");

        MLGMStatusSignal *network = [session parseLine:FunctionCall(
            @"2026-07-23T10:03:33.000Z", @"exec_command", @"{\"cmd\":\"pnpm install\"}"
        )];
        CHECK(network.kind == MLGMActivityNetwork, "dependency downloads should be Network");

        MLGMStatusSignal *approval = [session parseLine:FunctionCall(
            @"2026-07-23T10:03:34.000Z", @"request_permissions", @"{}"
        )];
        CHECK(approval.kind == MLGMActivityWaiting, "permission requests should be Waiting");

        MLGMDesktopLogParser *desktop = [MLGMDesktopLogParser new];
        MLGMStatusSignal *chatStart = [desktop parseLine:
            @"2026-07-23T12:00:00.000Z info [electron-message-handler] "
             "Reasoning summary turn-start config resolved conversationId=abc123 rendererWindowId=1"
        ];
        CHECK([chatStart.taskID isEqualToString:@"chat:abc123"], "desktop conversations should be tracked");

        MLGMStatusSignal *retry = [desktop parseLine:
            @"2026-07-23T12:00:05.000Z info [electron-message-handler] "
             "chatgpt_pubsub_reconnect_scheduled delayMs=250 retryCount=2"
        ];
        CHECK(retry.kind == MLGMActivityRetrying, "reconnect should be Network Retry");
        CHECK([desktop parseLine:
            @"2026-07-23T12:00:06.000Z info [AppServerConnection] "
             "response_routed durationMs=2 timeoutMs=30000 errorCode=null"
        ] == nil, "a timeoutMs configuration field must not be treated as a timeout");
        CHECK(MLGMElapsedSeconds(MLGMParseTimestamp(@"2026-07-23T00:00:00.000Z"),
                                 MLGMParseTimestamp(@"2026-07-24T00:00:00.000Z")) == 9999,
              "elapsed seconds should be capped at 9999");

        MLGMStatusStore *store = [MLGMStatusStore new];
        [store setTitles:@{@"thread-1": @"任务 A", @"thread-2": @"任务 B"}];
        [store applySignal:[MLGMStatusSignal started:@"thread-1" kind:MLGMActivityReasoning
                                                 at:MLGMParseTimestamp(@"2026-07-23T12:00:00.000Z")]];
        [store applySignal:[MLGMStatusSignal started:@"thread-2" kind:MLGMActivityNetwork
                                                 at:MLGMParseTimestamp(@"2026-07-23T12:00:05.000Z")]];
        CHECK([store.sortedTasks.firstObject.taskID isEqualToString:@"thread-2"],
              "most recently active task should be first");
        [store applySignal:[MLGMStatusSignal finished:@"thread-2"
                                                   at:MLGMParseTimestamp(@"2026-07-23T12:00:06.000Z")]];
        CHECK(store.sortedTasks.count == 1, "finished tasks should be removed");

        MLGMStatusStore *aliasStore = [MLGMStatusStore new];
        [aliasStore applySignal:[MLGMStatusSignal started:@"chat:thread-alias"
                                                     kind:MLGMActivityReasoning
                                                       at:MLGMParseTimestamp(@"2026-07-23T12:01:00.000Z")]];
        [aliasStore applySignal:[MLGMStatusSignal started:@"thread-alias"
                                                     kind:MLGMActivityReasoning
                                                       at:MLGMParseTimestamp(@"2026-07-23T12:01:01.000Z")]];
        CHECK(aliasStore.sortedTasks.count == 1,
              "a canonical task should replace its chat-prefixed alias");
        [aliasStore applySignal:[MLGMStatusSignal finished:@"thread-alias"
                                                        at:MLGMParseTimestamp(@"2026-07-23T12:01:02.000Z")]];
        [aliasStore applySignal:[MLGMStatusSignal activity:nil
                                                     kind:MLGMActivityRetrying
                                                       at:MLGMParseTimestamp(@"2026-07-23T12:01:03.000Z")]];
        CHECK(aliasStore.sortedTasks.count == 0,
              "finishing a task should also remove its chat-prefixed alias");

        MLGMStatusSignal *finish = [session parseLine:JSONLine(
            @"2026-07-23T10:04:00.000Z", @"event_msg", @{@"type": @"task_complete"}
        )];
        CHECK(finish.type == MLGMStatusSignalFinished, "task_complete should finish a task");

        NSString *realSession = NSProcessInfo.processInfo.environment[@"REAL_SESSION_LOG"];
        if (realSession.length) {
            NSString *contents = [NSString stringWithContentsOfFile:realSession
                                                           encoding:NSUTF8StringEncoding
                                                              error:nil];
            MLGMSessionLogParser *realParser = [[MLGMSessionLogParser alloc] initWithSessionID:@"real"];
            MLGMStatusStore *realStore = [MLGMStatusStore new];
            __block NSInteger recognized = 0;
            [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
                MLGMStatusSignal *signal = [realParser parseLine:line];
                if (signal) {
                    recognized++;
                    [realStore applySignal:signal];
                }
            }];
            CHECK(recognized > 0, "the current real session log should contain recognized status events");
            CHECK(realStore.sortedTasks.count == 1,
                  "the current in-progress session should remain visible as unfinished");
        }

        NSString *realDesktop = NSProcessInfo.processInfo.environment[@"REAL_DESKTOP_LOG"];
        if (realDesktop.length) {
            NSString *contents = [NSString stringWithContentsOfFile:realDesktop
                                                           encoding:NSUTF8StringEncoding
                                                              error:nil];
            MLGMDesktopLogParser *realParser = [MLGMDesktopLogParser new];
            __block NSInteger recognized = 0;
            [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
                if ([realParser parseLine:line]) recognized++;
            }];
            CHECK(recognized > 0, "the current real desktop log should contain recognized status events");
        }
    }
    if (failures == 0) {
        puts("All StatusCore tests passed.");
        return 0;
    }
    return 1;
}
