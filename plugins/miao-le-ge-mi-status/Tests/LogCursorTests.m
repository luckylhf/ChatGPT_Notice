#define main MLGMOriginalAppMain
#import "../Sources/main.m"
#undef main

static NSInteger failures = 0;

#define CHECK(condition, message) do { \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL: %s\n", message); \
    } \
} while (0)

int main(void) {
    @autoreleasepool {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"miao-log-cursor-%@.jsonl", NSUUID.UUID.UUIDString]];
        NSData *firstChunk = [@"{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
            dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *chunkWithPartialCharacter = [firstChunk mutableCopy];
        const unsigned char partialCharacter[] = {0xE4, 0xB8};
        [chunkWithPartialCharacter appendBytes:partialCharacter length:sizeof(partialCharacter)];
        [chunkWithPartialCharacter writeToFile:path atomically:YES];

        MLGMLogCursor *cursor = [[MLGMLogCursor alloc] initWithPath:path];
        NSArray<NSString *> *firstLines = [cursor readAvailableLines];
        CHECK(firstLines.count == 1,
              "a partial trailing UTF-8 character must not discard preceding complete log lines");
        CHECK([firstLines.firstObject containsString:@"task_started"],
              "the complete task_started line before a partial character must be retained");

        const unsigned char remainingCharacter[] = {0x96, 0xE7, 0x95, 0x8C, '\n'};
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:[NSData dataWithBytes:remainingCharacter length:sizeof(remainingCharacter)]];
        [handle closeFile];
        NSArray<NSString *> *secondLines = [cursor readAvailableLines];
        CHECK(secondLines.count == 1 && [secondLines.firstObject isEqualToString:@"世界"],
              "a UTF-8 character split across reads must be reassembled without losing bytes");
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
    if (failures == 0) {
        puts("All LogCursor tests passed.");
        return 0;
    }
    return 1;
}
