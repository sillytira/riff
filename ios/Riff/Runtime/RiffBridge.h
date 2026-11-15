#include "../../../native-codecs/bridge/RiffCodecs.h"
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Synchronous; called only from the dedicated extraction actor, never from the UI.
NSString *RiffPythonRequest(NSString *bundlePath, NSString *request);
NS_ASSUME_NONNULL_END
/// Coordinate File Provider reads so cloud-backed audio is materialized before copying.
NSError * _Nullable RiffCoordinatedFileCopy(NSURL * _Nonnull source, NSURL * _Nonnull destination);
