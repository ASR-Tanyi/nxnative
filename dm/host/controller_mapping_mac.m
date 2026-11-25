#import "controller_mapping_mac.h"
#import <Carbon/Carbon.h>
#include "mouse_look.h"

NSEventModifierFlags dm_mac_modifier_flag(unsigned code) {
    switch (mac_key_code(code)) {
    case MAC_SHIFT: return NSEventModifierFlagShift;
    case MAC_OPTION: return NSEventModifierFlagOption;
    case MAC_CONTROL: return NSEventModifierFlagControl;
    default: return 0;
    }
}

static NSData *keyboard_layout_data(void) {
    for (int i = 0; i < 2; i++) {
        TISInputSourceRef source = i ? TISCopyCurrentASCIICapableKeyboardLayoutInputSource() : TISCopyCurrentKeyboardLayoutInputSource();
        if (!source) continue;
        NSData *layout = (__bridge NSData *)TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
        CFRelease(source);
        if (layout.length) return layout;
    }
    return nil;
}
static NSString *input_name(int slot, NSData *layout) {
    if (slot < 0) return @"Add binding…";
    if (slot >= MAC_CLICK) return @[@"Left click", @"Right click", @"Middle click"][slot - MAC_CLICK];
    unsigned code = (unsigned)slot % MAC_KEY_COUNT;
    static NSDictionary<NSNumber *, NSString *> *names;
    if (!names) names = @{@36:@"Return", @48:@"Tab", @49:@"Space", @51:@"Delete", @56:@"Shift", @58:@"Option", @59:@"Control",
        @65:@"Keypad .", @67:@"Keypad ×", @69:@"Keypad +", @71:@"Keypad Clear", @75:@"Keypad ÷", @76:@"Keypad Enter",
        @78:@"Keypad −", @81:@"Keypad =", @82:@"Keypad 0", @83:@"Keypad 1", @84:@"Keypad 2", @85:@"Keypad 3",
        @86:@"Keypad 4", @87:@"Keypad 5", @88:@"Keypad 6", @89:@"Keypad 7", @91:@"Keypad 8", @92:@"Keypad 9",
        @114:@"Help", @115:@"Home", @116:@"Page Up", @117:@"Forward Delete", @119:@"End", @121:@"Page Down",
        @123:@"←", @124:@"→", @125:@"↓", @126:@"↑",
        @122:@"F1", @120:@"F2", @99:@"F3", @118:@"F4", @96:@"F5", @97:@"F6", @98:@"F7", @100:@"F8", @101:@"F9", @109:@"F10",
        @103:@"F11", @111:@"F12", @105:@"F13", @107:@"F14", @113:@"F15", @106:@"F16", @64:@"F17", @79:@"F18", @80:@"F19", @90:@"F20"};
    NSString *name = names[@(code)];
    if (!name && layout.length) {
        UniChar chars[8]; UniCharCount count = 0; UInt32 dead = 0;
        OSStatus err = UCKeyTranslate(layout.bytes, (UInt16)code, kUCKeyActionDisplay, 0, LMGetKbdType(), kUCKeyTranslateNoDeadKeysMask,
                                      &dead, sizeof chars / sizeof chars[0], &count, chars);
        if (err == noErr && count && ![NSCharacterSet.controlCharacterSet characterIsMember:chars[0]])
            name = [NSString stringWithCharacters:chars length:count].uppercaseString;
    }
    if (!name) name = [NSString stringWithFormat:@"Key %u", code];
    return slot >= MAC_SHIFTED ? [@"Shift + " stringByAppendingString:name] : name;
}

@interface DmMappingView : NSView @end
@implementation DmMappingView
- (BOOL)isFlipped { return YES; }
@end
@interface DmControllerFace : DmMappingView @end
@implementation DmControllerFace
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(160, 18)];
    [p curveToPoint:NSMakePoint(42, 89) controlPoint1:NSMakePoint(95, 9) controlPoint2:NSMakePoint(60, 33)];
    [p curveToPoint:NSMakePoint(33, 222) controlPoint1:NSMakePoint(25, 141) controlPoint2:NSMakePoint(9, 209)];
    [p curveToPoint:NSMakePoint(129, 191) controlPoint1:NSMakePoint(53, 240) controlPoint2:NSMakePoint(90, 221)];
    [p curveToPoint:NSMakePoint(220, 211) controlPoint1:NSMakePoint(158, 190) controlPoint2:NSMakePoint(180, 211)];
    [p lineToPoint:NSMakePoint(412, 211)];
    [p curveToPoint:NSMakePoint(505, 191) controlPoint1:NSMakePoint(460, 211) controlPoint2:NSMakePoint(477, 190)];
    [p curveToPoint:NSMakePoint(601, 222) controlPoint1:NSMakePoint(553, 223) controlPoint2:NSMakePoint(581, 239)];
    [p curveToPoint:NSMakePoint(592, 89) controlPoint1:NSMakePoint(626, 205) controlPoint2:NSMakePoint(605, 137)];
    [p curveToPoint:NSMakePoint(474, 18) controlPoint1:NSMakePoint(574, 32) controlPoint2:NSMakePoint(537, 9)];
    [p closePath]; [NSColor.controlBackgroundColor setFill]; [p fill]; [NSColor.separatorColor setStroke]; [p stroke];
}
@end

@interface DmControllerMapping ()
- (void)bindMouse:(NSEvent *)event;
@end
@interface DmBindingPad : NSButton
@property(weak) DmControllerMapping *mapping;
@end
@implementation DmBindingPad
- (void)mouseDown:(NSEvent *)event { [self.mapping bindMouse:event]; }
- (void)rightMouseDown:(NSEvent *)event { [self.mapping bindMouse:event]; }
- (void)otherMouseDown:(NSEvent *)event { [self.mapping bindMouse:event]; }
@end

@implementation DmControllerMapping {
    const mac_controls *_profile;
    NSError *(^_apply)(const mac_controls *);
    BOOL _mouse, _listening;
    int _oldSlot, _pendingModifier;
    uint64_t _action;
    NSPopUpButton *_mode, *_slots;
    NSMutableDictionary<NSNumber *, NSButton *> *_controls;
    NSTextField *_actionName, *_status, *_editing;
    NSButton *_remove, *_cancel;
    DmBindingPad *_pad;
    NSData *_layoutData;
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame in:(NSView *)view {
    NSTextField *label = [NSTextField labelWithString:text]; label.frame = frame; [view addSubview:label]; return label;
}
- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame in:(NSView *)view {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.frame = frame; [view addSubview:b]; return b;
}
- (void)addAction:(uint64_t)action title:(NSString *)title x:(int)x y:(int)y width:(int)width in:(NSView *)view {
    NSButton *b = [self button:title action:@selector(selectAction:) frame:NSMakeRect(x, y, width, 26) in:view];
    b.bezelStyle = NSBezelStyleFlexiblePush;
    NSString *name = @(mac_action_label(action));
    b.accessibilityLabel = name;
    _controls[@(action)] = b;
}
- (void)crossIn:(NSView *)view x:(int)x y:(int)y directions:(const uint64_t[4])dirs center:(uint64_t)center {
    [self addAction:dirs[0] title:@"↑" x:x y:y-27 width:34 in:view];
    [self addAction:dirs[1] title:@"←" x:x-36 y:y width:34 in:view];
    [self addAction:dirs[2] title:@"→" x:x+36 y:y width:34 in:view];
    [self addAction:dirs[3] title:@"↓" x:x y:y+27 width:34 in:view];
    if (center) [self addAction:center title:center == DM_BTN_LS ? @"LS" : @"RS" x:x y:y width:34 in:view];
}
- (instancetype)initWithGame:(NSString *)game profile:(const mac_controls *)profile
                       apply:(NSError *(^)(const mac_controls *))apply {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 680, 532)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:win])) return nil;
    _profile = profile; _apply = [apply copy]; _controls = [NSMutableDictionary dictionary];
    win.title = [@"Controller Mapping — " stringByAppendingString:game]; win.delegate = self;
    win.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    DmMappingView *root = [[DmMappingView alloc] initWithFrame:win.contentView.bounds]; win.contentView = root;
    [self label:@"Play mode" frame:NSMakeRect(24, 19, 75, 19) in:root];
    _mode = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(99, 13, 184, 28) pullsDown:NO];
    [_mode addItemsWithTitles:@[@"Follow Mouse Look", @"Keyboard + Mouse", @"Classic"]];
    _mode.target = self; _mode.action = @selector(changeMode:); _mode.accessibilityLabel = @"Play mode"; [root addSubview:_mode];
    _editing = [self label:@"" frame:NSMakeRect(290, 18, 365, 20) in:root]; _editing.alignment = NSTextAlignmentRight;
    _editing.textColor = NSColor.secondaryLabelColor;
    DmControllerFace *face = [[DmControllerFace alloc] initWithFrame:NSMakeRect(23, 46, 634, 239)]; [root addSubview:face];
    [self addAction:DM_BTN_ZL title:@"ZL" x:91 y:1 width:57 in:face]; [self addAction:DM_BTN_L title:@"L" x:153 y:1 width:50 in:face];
    [self addAction:DM_BTN_R title:@"R" x:431 y:1 width:50 in:face]; [self addAction:DM_BTN_ZR title:@"ZR" x:486 y:1 width:57 in:face];
    [self crossIn:face x:93 y:86 directions:(uint64_t[]){KEY_MOVE_UP, KEY_MOVE_LEFT, KEY_MOVE_RIGHT, KEY_MOVE_DOWN} center:DM_BTN_LS];
    [self crossIn:face x:194 y:151 directions:(uint64_t[]){DM_BTN_UP, DM_BTN_LEFT, DM_BTN_RIGHT, DM_BTN_DOWN} center:0];
    [self crossIn:face x:405 y:151 directions:(uint64_t[]){KEY_LOOK_UP, KEY_LOOK_LEFT, KEY_LOOK_RIGHT, KEY_LOOK_DOWN} center:DM_BTN_RS];
    NSTextField *groups[] = {
        [self label:@"Left stick" frame:NSMakeRect(62, 144, 96, 18) in:face],
        [self label:@"D-pad" frame:NSMakeRect(163, 207, 96, 18) in:face],
        [self label:@"Right stick" frame:NSMakeRect(374, 207, 96, 18) in:face],
    };
    for (unsigned i = 0; i < sizeof groups / sizeof groups[0]; i++) {
        groups[i].alignment = NSTextAlignmentCenter;
        groups[i].font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        groups[i].textColor = NSColor.secondaryLabelColor;
    }
    [self addAction:DM_BTN_MINUS title:@"−" x:261 y:57 width:40 in:face]; [self addAction:DM_BTN_PLUS title:@"+" x:333 y:57 width:40 in:face];
    [self addAction:DM_BTN_X title:@"X" x:507 y:58 width:34 in:face]; [self addAction:DM_BTN_Y title:@"Y" x:471 y:85 width:34 in:face];
    [self addAction:DM_BTN_A title:@"A" x:543 y:85 width:34 in:face]; [self addAction:DM_BTN_B title:@"B" x:507 y:112 width:34 in:face];
    [self addAction:KEY_WALK title:@"Walk" x:32 y:285 width:67 in:root]; [self addAction:KEY_SPRINT title:@"Sprint" x:106 y:285 width:67 in:root];
    [self addAction:DM_BTN_SHAKE title:@"Shake" x:180 y:285 width:67 in:root];
    NSTextField *motion = [self label:@"Mouse / trackpad movement → Right stick" frame:NSMakeRect(278, 289, 369, 20) in:root];
    motion.alignment = NSTextAlignmentRight; motion.textColor = NSColor.secondaryLabelColor;
    _actionName = [self label:@"" frame:NSMakeRect(28, 329, 188, 22) in:root]; _actionName.font = [NSFont boldSystemFontOfSize:14];
    _slots = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(218, 323, 194, 30) pullsDown:NO];
    _slots.autoenablesItems = NO;
    _slots.target = self; _slots.action = @selector(selectSlot:); _slots.accessibilityLabel = @"Assigned inputs"; [root addSubview:_slots];
    _remove = [self button:@"Remove" action:@selector(removeBinding:) frame:NSMakeRect(416, 322, 91, 32) in:root];
    [self button:@"Reset Control" action:@selector(resetControl:) frame:NSMakeRect(508, 322, 142, 32) in:root];
    _status = [self label:@"" frame:NSMakeRect(28, 365, 624, 38) in:root]; _status.maximumNumberOfLines = 2;
    _pad = [[DmBindingPad alloc] initWithFrame:NSMakeRect(24, 404, 420, 35)];
    _pad.mapping = self; _pad.title = @"Click here to bind a mouse or trackpad button"; _pad.bezelStyle = NSBezelStyleFlexiblePush;
    [root addSubview:_pad];
    _cancel = [self button:@"Cancel Capture" action:@selector(cancelCapture:) frame:NSMakeRect(454, 403, 193, 36) in:root];
    [self button:@"Reset All Bindings…" action:@selector(resetAll:) frame:NSMakeRect(23, 474, 168, 34) in:root];
    [self button:@"Done" action:@selector(close) frame:NSMakeRect(556, 474, 96, 34) in:root];
    [win center]; return self;
}
- (void)showEditingMouse:(BOOL)mouse {
    _mouse = mouse; if (!_action) _action = DM_BTN_A;
    [self refreshForSlot:-1]; [self stopListening:@"Click a controller input, then press the key you want to use."];
    [self showWindow:nil]; [self.window makeKeyAndOrderFront:nil];
}
- (void)profileChanged {
    if (!self.window.isVisible) return;
    if (_profile->preset != MAC_KEYS_AUTO) _mouse = _profile->preset == MAC_KEYS_MOUSE;
    [self refreshForSlot:_oldSlot]; [self cancelCapture:nil];
}
- (void)refreshForSlot:(int)preferred {
    [_mode selectItemAtIndex:_profile->preset];
    _editing.stringValue = _mouse ? @"Editing Keyboard + Mouse" : @"Editing Classic";
    _actionName.stringValue = @(mac_action_label(_action));
    [_slots removeAllItems];
    _layoutData = keyboard_layout_data();
    NSMutableDictionary<NSNumber *, NSMutableArray<NSString *> *> *bindings = [NSMutableDictionary dictionary];
    for (int i = 0; i < MAC_INPUT_COUNT; i++) {
        uint64_t action = mac_binding(_profile, _mouse, i);
        if (!action) continue;
        NSNumber *key = @(action);
        if (!bindings[key]) bindings[key] = [NSMutableArray array];
        NSString *name = input_name(i, _layoutData);
        [bindings[key] addObject:name];
        if (action == _action) {
            [_slots.menu addItemWithTitle:name action:nil keyEquivalent:@""].tag = i;
            if (preferred < 0 && mac_default_binding(_mouse, i) != action) preferred = i;
        }
    }
    [_controls enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSButton *b, BOOL *stop) {
        (void)stop; b.bezelColor = key.unsignedLongLongValue == self->_action ? NSColor.controlAccentColor : nil;
        NSString *assigned = [bindings[key] componentsJoinedByString:@", "] ?: @"Unassigned";
        b.toolTip = [NSString stringWithFormat:@"%@ — %@", b.accessibilityLabel, assigned];
        b.accessibilityHelp = assigned;
    }];
    [_slots addItemWithTitle:input_name(-1, _layoutData)]; _slots.lastItem.tag = -1;
    if (preferred < 0 && _mouse) {
        // Start with the usual gameplay input when the default also has a keyboard alias.
        switch (_action) {
        case DM_BTN_X: preferred = 49; break;   // Space
        case DM_BTN_Y: preferred = MAC_CLICK + MOUSE_LEFT; break;
        case DM_BTN_ZR: preferred = MAC_CLICK + MOUSE_RIGHT; break;
        case DM_BTN_RS: preferred = MAC_CLICK + MOUSE_MIDDLE; break;
        }
    }
    if (preferred >= 0 && [_slots.menu itemWithTag:preferred]) [_slots selectItemWithTag:preferred]; else [_slots selectItemAtIndex:0];
    _oldSlot = (int)_slots.selectedItem.tag; _remove.enabled = _oldSlot >= 0;
}
- (void)stopListening:(NSString *)message {
    _listening = NO; _pendingModifier = -1; _pad.enabled = NO; _cancel.enabled = NO; _status.stringValue = message;
}
- (void)selectSlot:(id)sender {
    (void)sender;
    _oldSlot = (int)_slots.selectedItem.tag; _remove.enabled = _oldSlot >= 0;
    _listening = YES; _pendingModifier = -1; _pad.enabled = YES; _cancel.enabled = YES;
    _status.stringValue = [NSString stringWithFormat:@"Press a key for %@, or click the mouse binding area. Escape cancels.", _actionName.stringValue];
}
- (void)selectAction:(NSButton *)sender {
    _action = [_controls allKeysForObject:sender].firstObject.unsignedLongLongValue;
    [self refreshForSlot:-1]; [self selectSlot:nil];
}
- (BOOL)commit:(const mac_controls *)next preferred:(int)slot message:(NSString *)message {
    NSError *error = _apply(next);
    [self refreshForSlot:slot];
    [self stopListening:error ? error.localizedDescription : message];
    if (error) NSBeep();
    return !error;
}
- (void)changeMode:(NSPopUpButton *)sender {
    mac_controls next = *_profile; next.preset = (mac_key_preset)sender.indexOfSelectedItem;
    if ([self commit:&next preferred:-1 message:@"Select a controller input to change its binding."]) {
        if (next.preset != MAC_KEYS_AUTO) _mouse = next.preset == MAC_KEYS_MOUSE;
        [self refreshForSlot:-1];
    }
}
- (void)assign:(int)slot {
    if (!_listening || !mac_bindable(slot)) return;
    uint64_t previous = mac_binding(_profile, _mouse, slot);
    mac_controls next = *_profile; mac_rebind(&next, _mouse, _action, _oldSlot, slot);
    NSString *message = previous && previous != _action ?
        [NSString stringWithFormat:@"%@ moved from %@ to %@.", input_name(slot, _layoutData), @(mac_action_label(previous)), _actionName.stringValue] :
        [NSString stringWithFormat:@"%@ is now bound to %@.", input_name(slot, _layoutData), _actionName.stringValue];
    [self commit:&next preferred:slot message:message];
}
- (void)bindMouse:(NSEvent *)e {
    NSUInteger n = (NSUInteger)e.buttonNumber;
    if (!_listening || n >= MOUSE_BUTTONS) return;
    [self assign:MAC_CLICK + mouse_look_button((unsigned)n, !!(e.modifierFlags & NSEventModifierFlagOption), !!(e.modifierFlags & NSEventModifierFlagControl))];
}
- (BOOL)captureEvent:(NSEvent *)e {
    if (!_listening || (e.window && e.window != self.window)) return NO;
    if (e.type != NSEventTypeKeyDown && e.type != NSEventTypeKeyUp && e.type != NSEventTypeFlagsChanged) return NO;
    if (e.modifierFlags & NSEventModifierFlagCommand) { _pendingModifier = -1; return NO; }
    unsigned code = mac_key_code(e.keyCode);
    if (e.type == NSEventTypeFlagsChanged) {
        NSEventModifierFlags flag = dm_mac_modifier_flag(code);
        if (flag && (e.modifierFlags & flag)) _pendingModifier = (int)code;
        else if (flag && _pendingModifier == (int)code) [self assign:(int)code];
        return YES;
    }
    if (e.type == NSEventTypeKeyUp || e.isARepeat) return YES;
    _pendingModifier = -1;
    if (code == MAC_ESCAPE) { [self cancelCapture:nil]; return YES; }
    if (e.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagOption)) {
        _status.stringValue = @"Use a single key or Shift + key. To bind Control or Option alone, press and release it."; return YES;
    }
    if (code >= MAC_KEY_COUNT || !mac_bindable((int)code) || ((e.modifierFlags & NSEventModifierFlagFunction) &&
        e.charactersIgnoringModifiers.length == 1 && [NSCharacterSet.letterCharacterSet characterIsMember:[e.charactersIgnoringModifiers characterAtIndex:0]])) return NO;
    [self assign:(int)code + ((e.modifierFlags & NSEventModifierFlagShift) ? MAC_SHIFTED : 0)]; return YES;
}
- (void)removeBinding:(id)sender {
    (void)sender; mac_controls next = *_profile; mac_rebind(&next, _mouse, _action, _oldSlot, -1);
    [self commit:&next preferred:-1 message:@"Binding removed."];
}
- (void)resetControl:(id)sender {
    (void)sender; mac_controls next = *_profile; mac_reset_action(&next, _mouse, _action);
    [self commit:&next preferred:-1 message:@"Default bindings restored for this control."];
}
- (void)resetAll:(id)sender {
    (void)sender; [self cancelCapture:nil];
    NSAlert *a = [NSAlert new]; a.messageText = @"Reset all bindings for this game?";
    a.informativeText = @"Both keyboard layouts and all three mouse clicks will return to their defaults.";
    [a addButtonWithTitle:@"Cancel"]; [a addButtonWithTitle:@"Reset All Bindings"];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSAlertSecondButtonReturn) return;
        mac_controls next = *self->_profile; mac_reset_bindings(&next);
        [self commit:&next preferred:-1 message:@"Default bindings restored."];
    }];
}
- (void)cancelCapture:(id)sender { (void)sender; [self stopListening:@"Select a controller input to change its binding."]; }
- (void)windowDidResignKey:(NSNotification *)note { (void)note; if (_listening) [self cancelCapture:nil]; }
@end
