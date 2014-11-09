//
//  QSLMUMonitor.h
//  Nocturne
//
//  Created by Dominik Pich 11/2013
/**
 * based loosly on code:
 * Created by Nicholas Jitkoff on 5/14/07.
 * Copyright 2007 Blacktree. All rights reserved.
 */
#include <Foundation/Foundation.h>

@class QSLMUMonitor;

@protocol QSLMUMonitorDelegate <NSObject>
- (void)monitor:(QSLMUMonitor *)monitor passedLowerBound:(uint64_t)lowerBound withValue:(uint64_t)value;
- (void)monitor:(QSLMUMonitor *)monitor passedUpperBound:(uint64_t)upperBound withValue:(uint64_t)value;
@end

@interface QSLMUMonitor : NSObject

@property(nonatomic, weak) id<QSLMUMonitorDelegate> delegate;
//@property(nonatomic, assign) BOOL doKVO; //defaults to NO

//kvo
@property(nonatomic, readonly) NSNumber *percent;

@property(nonatomic, assign) uint64_t lowerBound;
@property(nonatomic, assign) uint64_t upperBound;
@property(nonatomic, assign) BOOL monitorSensors;

///set to 0 for default interval (a few seconds)
@property(nonatomic, assign) NSTimeInterval pollFrequency;

+ (BOOL)hasSensors;

@end