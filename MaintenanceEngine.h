#import <Foundation/Foundation.h>

// «Ускориться» (v0.15.0): safe, reversible tidy-up for old Macs. Foundation only, no root, no timers:
// it runs only when the person presses the button, on a background-QoS queue (the system throttles
// its disk I/O, which matters on a spinning HDD).
//
// What it does (the safe subset of macOS_maintenance_idempotent.md — see handoff.md section 22):
//   1. moves REGULAR files from ~/Library/Caches older than 30 days and from ~/Library/Logs older than
//      90 days into one folder MacMaintenance-<stamp> and puts that folder into the Trash (a move,
//      never a delete);
//   2. deletes only those folders of its own from the Trash, a week later — that is what finally
//      frees the space, and it never reads or touches anything else in the Trash;
//   3. turns window / Dock / Finder animations down (reversible: the original values are saved).
@interface RKTuneReport : NSObject
@property (assign) unsigned long long movedBytes;      // moved to the Trash by this run
@property (assign) NSUInteger         movedFiles;
@property (assign) BOOL               trashFailed;     // the Trash refused the folder: files wait in Raketa's support folder
@property (assign) unsigned long long purgedBytes;     // freed by deleting our own week-old Trash folders
@property (assign) BOOL               animationsChanged;
@property (assign) long long          freeBytes;       // free space on the home volume after the run, -1 unknown
@end

@interface MaintenanceEngine : NSObject
@property (nonatomic, readonly) BOOL animationsTweaked;        // our animation settings are in force
// Background work; `done` is called on the main queue.
- (void)runWithCompletion:(void (^)(RKTuneReport *report))done;
// Puts the saved original animation values back. Main thread. NO if there was nothing to restore.
- (BOOL)restoreAnimations;
@end
