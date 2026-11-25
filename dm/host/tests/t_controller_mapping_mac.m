// Exercise the real AppKit controls offscreen, using the same save callback and key events as the game window.
#import "../controller_mapping_mac.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>

static NSButton *button(NSView *view, NSString *label) {
    if ([view isKindOfClass:NSButton.class]) {
        NSButton *b = (NSButton *)view;
        if ([b.accessibilityLabel isEqualToString:label] || [b.title isEqualToString:label]) return b;
    }
    for (NSView *child in view.subviews) {
        NSButton *b = button(child, label);
        if (b) return b;
    }
    return nil;
}
static NSEvent *key(NSWindow *w, NSEventType type, unsigned short code, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:w.windowNumber
                             context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
}
static void choose(NSPopUpButton *p, NSInteger tag) {
    assert([p selectItemWithTag:tag]); [p sendAction:p.action to:p.target];
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        static mac_controls profile;
        mac_controls_init(&profile);
        __block BOOL reject = NO;
        DmControllerMapping *editor = [[DmControllerMapping alloc] initWithGame:@"Test" profile:&profile apply:^NSError *(const mac_controls *p) {
            if (reject) return [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];
            profile = *p; return nil;
        }];
        NSWindow *w = editor.window;
        NSView *root = w.contentView;
        NSButton *a = button(root, @"A button"), *up = button(root, @"Left stick up"), *right = button(root, @"Right stick right");
        NSButton *reset = button(root, @"Reset Control"), *remove = button(root, @"Remove");
        NSButton *pad = button(root, @"Click here to bind a mouse or trackpad button");
        NSPopUpButton *mode = (id)button(root, @"Play mode"), *slots = (id)button(root, @"Assigned inputs");
        assert(a && up && right && reset && remove && pad && mode && slots);
        [a performClick:nil];
        [mode selectItemAtIndex:MAC_KEYS_MOUSE]; [mode sendAction:mode.action to:mode.target];
        assert(profile.preset == MAC_KEYS_MOUSE);
        [a performClick:nil]; choose(slots, 14);   // replace E with F, leaving Return and J
        NSEvent *f = key(w, NSEventTypeKeyDown, 3, 0);
        assert([editor captureEvent:f] && ![editor captureEvent:f]);
        assert(mac_binding(&profile, true, 3) == DM_BTN_A && !mac_binding(&profile, true, 14));
        assert(mac_binding(&profile, true, 38) == DM_BTN_A && mac_binding(&profile, false, 3) == DM_BTN_LS);
        [a performClick:nil]; choose(slots, -1);
        NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:NSZeroPoint modifierFlags:0 timestamp:0
            windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        [pad rightMouseDown:click];
        assert(profile.clicks[1] == DM_BTN_A && mac_binding(&profile, true, 3) == DM_BTN_A);
        assert(slots.selectedItem.tag == MAC_CLICK + 1);
        [remove performClick:nil]; assert(!profile.clicks[1]);
        [reset performClick:nil]; assert(mac_binding(&profile, true, 14) == DM_BTN_A && mac_binding(&profile, true, 3) == DM_BTN_L);
        [right performClick:nil]; choose(slots, -1);
        assert([editor captureEvent:key(w, NSEventTypeKeyDown, 3, NSEventModifierFlagShift)]);
        assert(mac_binding(&profile, true, MAC_SHIFTED + 3) == KEY_LOOK_RIGHT);
        [up performClick:nil]; choose(slots, -1);
        assert([editor captureEvent:key(w, NSEventTypeFlagsChanged, MAC_CONTROL, NSEventModifierFlagControl)]);
        assert([editor captureEvent:key(w, NSEventTypeFlagsChanged, MAC_CONTROL, 0)]);
        assert(mac_binding(&profile, true, MAC_CONTROL) == KEY_MOVE_UP);
        [up performClick:nil]; assert([editor captureEvent:key(w, NSEventTypeKeyDown, MAC_ESCAPE, 0)]);
        assert(![editor captureEvent:f] && mac_binding(&profile, true, 3) == DM_BTN_L);
        reject = YES; [up performClick:nil]; assert([editor captureEvent:f]);
        assert(mac_binding(&profile, true, 3) == DM_BTN_L && mac_binding(&profile, true, 13) == KEY_MOVE_UP);
    }
    puts("PASS: controller diagram, mode, key and click capture, aliases, reset, cancellation and save errors");
    return 0;
}
