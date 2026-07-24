#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MLGMActivityKind) {
    MLGMActivityReasoning,
    MLGMActivityExecuting,
    MLGMActivityGit,
    MLGMActivityNetwork,
    MLGMActivityReplying,
    MLGMActivityWaiting,
    MLGMActivityRetrying,
};

typedef NS_ENUM(NSInteger, MLGMStatusSignalType) {
    MLGMStatusSignalStarted,
    MLGMStatusSignalActivity,
    MLGMStatusSignalFinished,
};

FOUNDATION_EXPORT NSString *MLGMActivityLabel(MLGMActivityKind kind);
FOUNDATION_EXPORT NSDate * _Nullable MLGMParseTimestamp(NSString *value);
FOUNDATION_EXPORT NSInteger MLGMElapsedSeconds(NSDate *eventDate, NSDate *now);

@interface MLGMStatusSignal : NSObject
@property(nonatomic) MLGMStatusSignalType type;
@property(nonatomic, copy, nullable) NSString *taskID;
@property(nonatomic) MLGMActivityKind kind;
@property(nonatomic, strong) NSDate *date;
+ (instancetype)started:(NSString *)taskID kind:(MLGMActivityKind)kind at:(NSDate *)date;
+ (instancetype)activity:(nullable NSString *)taskID kind:(MLGMActivityKind)kind at:(NSDate *)date;
+ (instancetype)finished:(NSString *)taskID at:(NSDate *)date;
@end

@interface MLGMTaskStatus : NSObject
@property(nonatomic, copy) NSString *taskID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic) MLGMActivityKind kind;
@property(nonatomic, strong) NSDate *lastEventAt;
@end

@interface MLGMStatusStore : NSObject
@property(nonatomic, readonly) NSArray<MLGMTaskStatus *> *sortedTasks;
- (void)setTitles:(NSDictionary<NSString *, NSString *> *)titles;
- (void)applySignal:(MLGMStatusSignal *)signal;
@end

@interface MLGMSessionLogParser : NSObject
@property(nonatomic, readonly) NSString *sessionID;
- (instancetype)initWithSessionID:(NSString *)sessionID;
- (nullable MLGMStatusSignal *)parseLine:(NSString *)line;
@end

@interface MLGMDesktopLogParser : NSObject
- (nullable MLGMStatusSignal *)parseLine:(NSString *)line;
@end

NS_ASSUME_NONNULL_END
