//
//  NSWindow+Sticky.m
//  Nocturne
//
//  Created by Dominik Pich on 07/11/13.
//
//

#import "NSWindow+Sticky.h"
#import "CGSPrivate.h"

@implementation NSWindow (sticky)

- (void) setSticky:(BOOL)flag {
    CGSConnection cid;
    CGWindowID wid;
    
    wid = (CGSWindow)[self windowNumber];
    
    cid = _CGSDefaultConnection();
    CGSWindowTag tags[2] = { 0, 0 };
    
    if (!CGSGetWindowTags(cid, wid, tags, 32)) {
        if (flag) {
            tags[0] = tags[0] | 0x00000800;
        } else {
            tags[0] = tags[0] & ~0x00000800;
        }
        CGSSetWindowTags(cid, wid, tags, 32);
    }
}

@end

