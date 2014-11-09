/* QSNocturneController */

#import <Cocoa/Cocoa.h>
#import "QSLMUMonitor.h"

@interface QSNocturneController : NSObject <QSLMUMonitorDelegate, NSApplicationDelegate, NSWindowDelegate>

- (IBAction)toggleMode:(id)sender;
- (IBAction)changeHotkey:(id)sender;
- (IBAction)showPreferences:(id)sender;
- (IBAction)resetTint:(id)sender;

- (void)setDesktopHidden:(BOOL)hidden;

- (BOOL)enabled;
- (void)setEnabled:(BOOL)value;

- (NSColor *)whiteColor;
- (void)setWhiteColor:(NSColor *)value;

- (NSColor *)blackColor;
- (void)setBlackColor:(NSColor *)value;

- (void)updateGamma;

- (float)getDisplayBrightness;

- (QSLMUMonitor *)lightMonitor;

- (void)removeOverlays;
- (void)setupOverlays;

@end
