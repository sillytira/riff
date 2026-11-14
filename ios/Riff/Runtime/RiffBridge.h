#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Synchronous; called only from the dedicated extraction actor, never from the UI.
NSString *RiffPythonRequest(NSString *bundlePath, NSString *request);
NS_ASSUME_NONNULL_END
