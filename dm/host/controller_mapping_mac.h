#import <Cocoa/Cocoa.h>
#include "control_profile_mac.h"

@interface DmControllerMapping : NSWindowController <NSWindowDelegate>
- (instancetype)initWithGame:(NSString *)game profile:(const mac_controls *)profile
                       apply:(NSError *(^)(const mac_controls *candidate))apply;
- (void)showEditingMouse:(BOOL)mouse;
- (void)profileChanged;
// The game forwards local keyboard events while the editor is the active key window.
- (BOOL)captureEvent:(NSEvent *)event;
@end

NSEventModifierFlags dm_mac_modifier_flag(unsigned code);
