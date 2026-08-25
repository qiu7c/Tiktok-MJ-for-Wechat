#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const MJEnabledKey;
FOUNDATION_EXPORT void MJPlayEasterEgg(void);
FOUNDATION_EXPORT BOOL MJAlphaAssetsReady(void);
FOUNDATION_EXPORT void MJEnsureAssetsReady(void (^completion)(BOOL success, NSString *errorMessage));
FOUNDATION_EXPORT void MJDeleteLocalAssets(void);
