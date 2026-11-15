#include "../../../native-codecs/bridge/RiffCodecs.h"
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Synchronous; called only from the dedicated extraction actor, never from the UI.
NSString *RiffPythonRequest(NSString *bundlePath, NSString *request);
/// Raw DEFLATE compatible with desktop Riff. Rejects output above 16 MiB.
NSData * _Nullable RiffArchiveTransform(NSData *input, BOOL decompress);
NSData * _Nullable RiffBackupKey(NSData *password, NSData *salt, uint32_t rounds);
NS_ASSUME_NONNULL_END
