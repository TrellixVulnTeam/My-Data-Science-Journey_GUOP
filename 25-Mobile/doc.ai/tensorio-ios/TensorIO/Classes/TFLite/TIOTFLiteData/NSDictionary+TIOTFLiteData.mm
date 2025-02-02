//
//  NSDictionary+TIOTFLiteData.mm
//  TensorIO
//
//  Created by Philip Dow on 8/6/18.
//  Copyright © 2018 doc.ai (http://doc.ai)
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "NSDictionary+TIOTFLiteData.h"

@implementation NSDictionary (TIOTFLiteData)

- (nullable instancetype)initWithData:(NSData *)data description:(id<TIOLayerDescription>)description {
    NSAssert(NO, @"This method is unimplemented. A dictionary cannot be constructed directly from a tensor.");
    return [self init];
}

- (NSData *)dataForDescription:(id<TIOLayerDescription>)description {
    NSAssert(NO, @"This method is unimplemented. Tensor bytes cannot be captured from a dictionary.");
    return nil;
}

+ (NSMutableData *)bufferForDescription:(id<TIOLayerDescription>)description {
    NSAssert(NO, @"This method is unimplemented. Tensor bytes cannot be captured from a dictionary.");
    return nil;
}

@end
