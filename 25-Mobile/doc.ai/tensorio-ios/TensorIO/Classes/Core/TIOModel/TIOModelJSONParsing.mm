//
//  TIOModelJSONParsing.mm
//  TensorIO
//
//  Created by Philip Dow on 8/20/18.
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

#import "TIOModelJSONParsing.h"

#import "NSArray+TIOExtensions.h"
#import "TIOModelBundle.h"
#import "TIOLayerInterface.h"
#import "TIOPixelBufferLayerDescription.h"
#import "TIOVectorLayerDescription.h"
#import "TIOStringLayerDescription.h"
#import "TIOScalarLayerDescription.h"

static NSError * const kTIOParserInvalidPixelNormalizationError = [NSError errorWithDomain:@"ai.doc.tensorio" code:201 userInfo:@{
    NSLocalizedDescriptionKey: @"Unable to parse normalize field in description of input or output layer"
}];

static NSError * const kTIOParserInvalidPixelDenormalizationError = [NSError errorWithDomain:@"ai.doc.tensorio" code:202 userInfo:@{
    NSLocalizedDescriptionKey: @"Unable to parse the denormalize field in description of input or output layer"
}];

static NSError * const kTIOParserInvalidQuantizerError = [NSError errorWithDomain:@"ai.doc.tensorio" code:203 userInfo:@{
    NSLocalizedDescriptionKey: @"Unable to parse the quantize field in description of input or output layer"
}];

static NSError * const kTIOParserInvalidDequantizerError = [NSError errorWithDomain:@"ai.doc.tensorio" code:204 userInfo:@{
    NSLocalizedDescriptionKey: @"Unable to parse the dequantize field in description of input or output layer"
}];

// MARK: - Top Level Parsing

NSArray<TIOLayerInterface*> * _Nullable TIOModelParseIO(TIOModelBundle * _Nullable bundle, NSArray<NSDictionary<NSString*,id>*> *io, TIOLayerInterfaceMode mode) {
    static NSString * const kTensorTypeVector = @"array";
    static NSString * const kTensorTypeImage = @"image";
    static NSString * const kTensorTypeString = @"string";
    static NSString * const kTensorTypeScalar = @"scalar";
    
    NSMutableArray<TIOLayerInterface*> *interfaces = NSMutableArray.array;
    BOOL isQuantized = bundle.quantized; // Always NO (ignored) if bundle is nil
    
    __block BOOL error = NO;
    [io enumerateObjectsUsingBlock:^(NSDictionary<NSString *,id> * _Nonnull input, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *type = input[@"type"];
        TIOLayerInterface *interface;
        
        if ( [type isEqualToString:kTensorTypeVector] ) {
            interface = TIOModelParseTIOVectorDescription(input, mode, isQuantized, bundle);
        } else if ( [type isEqualToString:kTensorTypeImage] ) {
            interface = TIOModelParseTIOPixelBufferDescription(input, mode, isQuantized);
        } else if ( [type isEqualToString:kTensorTypeString] ) {
            interface = TIOModelParseTIOStringDescription(input, mode, isQuantized);
        } else if ( [type isEqualToString:kTensorTypeScalar] ) {
            interface = TIOModelParseTIOScalarDescription(input, mode, isQuantized);
        }
        
        if ( interface == nil ) {
            error = YES;
            *stop = YES;
            return;
        }
        
        [interfaces addObject:interface];
    }];
    
    return error ? nil : interfaces.copy;
}

TIOLayerInterface * _Nullable TIOModelParseTIOVectorDescription(NSDictionary *dict, TIOLayerInterfaceMode mode, BOOL quantized, TIOModelBundle *_Nullable bundle) {
    NSArray<NSNumber*> *shape = dict[@"shape"];
    BOOL batched = shape[0].integerValue == -1;
    NSString *name = dict[@"name"];

    // Labels

    NSArray<NSString*> *labels = nil;

    if ( NSString *labelsFilename = dict[@"labels"] ) {
        if ( bundle == nil ) {
            NSLog(@"Bundle is nil but labels values are provided");
            return nil;
        }
        
        NSError *error = nil;
        labels = [[NSString stringWithContentsOfFile:[bundle pathToAsset:labelsFilename] encoding:NSUTF8StringEncoding error:&error] componentsSeparatedByString:@"\n"];
        
        if ( error ) {
            NSLog(@"There was a problem reading %@, no labels were loaded", [bundle pathToAsset:labelsFilename]);
            labels = nil;
        }
    }
    
    // Data Type
    
    TIODataType dtype = TIODataTypeForString(dict[@"dtype"]);
    
    // Quantization
    
    TIODataQuantizer quantizer;
    
    switch (mode) {
    case TIOLayerInterfaceModeInput:
    case TIOLayerInterfaceModePlaceholder:
        {
        NSError *error;
        quantizer = TIODataQuantizerForDict(dict[@"quantize"], &error);
        if ( error != nil ) {
            NSLog(@"Expected quantize.standard string to be '[0,1]' or '[-1,1]', or to find scale and bias values, found: %@", dict);
            return nil;
        }
        }
        break;
    case TIOLayerInterfaceModeOutput:
        quantizer = TIODataQuantizerNone();
        break;
    }
    
    // Dequantization
    
    TIODataDequantizer dequantizer;
    
    switch (mode) {
    case TIOLayerInterfaceModeOutput:
        {
        NSError *error;
        dequantizer = TIODataDequantizerForDict(dict[@"dequantize"], &error);
        if ( error != nil ) {
            NSLog(@"Expected dequantize.standard string to be '[0,1]' or '[-1,1]', or to find scale and bias values, found: %@", dict);
            return nil;
        }
        }
        break;
    case TIOLayerInterfaceModeInput:
    case TIOLayerInterfaceModePlaceholder:
        dequantizer = TIODataDequantizerNone();
        break;
    }
    
    // Interface

    TIOLayerInterface *interface = [[TIOLayerInterface alloc] initWithName:name JSON:dict mode:mode vectorDescription:
        [[TIOVectorLayerDescription alloc]
            initWithShape:shape
            batched:batched
            dtype:dtype
            labels:labels
            quantized:quantized
            quantizer:quantizer
            dequantizer:dequantizer]];
    
    return interface;
}

TIOLayerInterface * _Nullable TIOModelParseTIOScalarDescription(NSDictionary *dict, TIOLayerInterfaceMode mode, BOOL quantized) {
    NSArray<NSNumber*> *shape = dict[@"shape"];
    BOOL batched = shape[0].integerValue == -1;
    NSString *name = dict[@"name"];
    
    // Data Type
    
    TIODataType dtype = TIODataTypeForString(dict[@"dtype"]);
    
    // Quantization
    
    TIODataQuantizer quantizer;
    
    switch (mode) {
    case TIOLayerInterfaceModeInput:
    case TIOLayerInterfaceModePlaceholder:
        {
        NSError *error;
        quantizer = TIODataQuantizerForDict(dict[@"quantize"], &error);
        if ( error != nil ) {
            NSLog(@"Expected quantize.standard string to be '[0,1]' or '[-1,1]', or to find scale and bias values, found: %@", dict);
            return nil;
        }
        }
        break;
    case TIOLayerInterfaceModeOutput:
        quantizer = TIODataQuantizerNone();
        break;
    }
    
    // Dequantization
    
    TIODataDequantizer dequantizer;
    
    switch (mode) {
    case TIOLayerInterfaceModeOutput:
        {
        NSError *error;
        dequantizer = TIODataDequantizerForDict(dict[@"dequantize"], &error);
        if ( error != nil ) {
            NSLog(@"Expected dequantize.standard string to be '[0,1]' or '[-1,1]', or to find scale and bias values, found: %@", dict);
            return nil;
        }
        }
        break;
    case TIOLayerInterfaceModeInput:
    case TIOLayerInterfaceModePlaceholder:
        dequantizer = TIODataDequantizerNone();
        break;
    }
    
    // Interface
    
    TIOLayerInterface *interface = [[TIOLayerInterface alloc] initWithName:name JSON:dict mode:mode scalarDescription:
        [[TIOScalarLayerDescription alloc]
            initWithShape:shape
            batched:batched
            dtype:dtype
            quantized:quantized
            quantizer:quantizer
            dequantizer:dequantizer]];
            
    return interface;
}

TIOLayerInterface * _Nullable TIOModelParseTIOPixelBufferDescription(NSDictionary *dict, TIOLayerInterfaceMode mode, BOOL quantized) {
    NSArray<NSNumber*> *shape = dict[@"shape"];
    BOOL batched = shape[0].integerValue == -1;
    NSString *name = dict[@"name"];
    
    // Image Volume
    
    TIOImageVolume imageVolume = TIOImageVolumeForShape(shape);
    
    if ( TIOImageVolumesEqual(imageVolume, kTIOImageVolumeInvalid ) ) {
        NSLog(@"Expected dict.shape array field with three elements in model.json, found %@", dict[@"shape"]);
        return nil;
    }
    
    // Pixel Format

    OSType pixelFormat = TIOPixelFormatForString(dict[@"format"]);

    if ( pixelFormat == TIOPixelFormatTypeInvalid ) {
        NSLog(@"Expected dict.format string to be RGB or BGR in model.json, found %@", dict[@"format"]);
        return nil;
    }
    
    // Normalization
    
    TIOPixelNormalizer normalizer;
    
    switch (mode) {
    case TIOLayerInterfaceModeInput:
    case TIOLayerInterfaceModePlaceholder:
        {
        NSError *error;
        normalizer = TIOPixelNormalizerForDictionary(dict[@"normalize"], &error);
        if ( error != nil ) {
            NSLog(@"Expected normalize.standard string to be '[0,1]' or '[-1,1]', or to find scale and bias values, found: %@", dict[@"normalize"]);
            return nil;
        }
        }
        break;
    case TIOLayerInterfaceModeOutput:
        normalizer = TIOPixelNormalizerNone();
        break;
    }
    
    // Denormalization
    
    TIOPixelDenormalizer denormalizer;

    switch (mode) {
    case TIOLayerInterfaceModeOutput:
        {
        NSError *error;
        denormalizer = TIOPixelDenormalizerForDictionary(dict[@"denormalize"], &error);
        if ( error != nil ) {
            NSLog(@"Expected denormalize string to be '[0,1]' or '[-1,1]', or to find scale and bias values, found: %@", dict[@"normalize"]);
            return nil;
        }
        }
        break;
    case TIOLayerInterfaceModeInput:
    case TIOLayerInterfaceModePlaceholder:
        denormalizer = TIOPixelDenormalizerNone();
        break;
    }

    // Description
    
    TIOLayerInterface *interface = [[TIOLayerInterface alloc] initWithName:name JSON:dict mode:mode pixelBufferDescription:
        [[TIOPixelBufferLayerDescription alloc]
            initWithPixelFormat:pixelFormat
            shape:shape
            imageVolume:imageVolume
            batched:batched
            normalizer:normalizer
            denormalizer:denormalizer
            quantized:quantized]];
    
    return interface;
}

TIOLayerInterface * _Nullable TIOModelParseTIOStringDescription(NSDictionary *dict, TIOLayerInterfaceMode mode, BOOL quantized) {
    NSArray<NSNumber*> *shape = dict[@"shape"];
    BOOL batched = shape[0].integerValue == -1;
    NSString *name = dict[@"name"];
    
    // Data Type
    
    TIODataType dtype = TIODataTypeForString(dict[@"dtype"]);
    
    // Interface
    
    TIOLayerInterface *interface = [[TIOLayerInterface alloc] initWithName:name JSON:dict mode:mode stringDescription:
        [[TIOStringLayerDescription alloc]
            initWithShape:shape
            batched:batched
            dtype:dtype]];
    
    return interface;
}

// MARK: - Vector Quantization

_Nullable TIODataQuantizer TIODataQuantizerForDict(NSDictionary * _Nullable dict, NSError **error) {
    if ( dict == nil ) {
        return nil;
    }
    
    NSString *standard = dict[@"standard"];
    NSNumber *scale = dict[@"scale"];
    NSNumber *bias = dict[@"bias"];
    
    if ( [standard isEqualToString:@"[0,1]"] ) {
        return TIODataQuantizerZeroToOne();
    }
    else if ( [standard isEqualToString:@"[-1,1]"] ) {
        return TIODataQuantizerNegativeOneToOne();
    }
    else if ( standard != nil ) {
        *error = kTIOParserInvalidQuantizerError;
        return nil;
    }
    else if ( scale != nil && bias != nil ) {
        return TIODataQuantizerWithQuantization({
            .scale = scale.floatValue,
            .bias = bias.floatValue
        });
    }
    else {
        *error = kTIOParserInvalidQuantizerError;
        return nil;
    }
}

_Nullable TIODataDequantizer TIODataDequantizerForDict(NSDictionary * _Nullable dict, NSError **error) {
    if ( dict == nil ) {
        return nil;
    }
    
    NSString *standard = dict[@"standard"];
    NSNumber *scale = dict[@"scale"];
    NSNumber *bias = dict[@"bias"];
    
    if ( [standard isEqualToString:@"[0,1]"] ) {
        return TIODataDequantizerZeroToOne();
    }
    else if ( [standard isEqualToString:@"[-1,1]"] ) {
        return TIODataDequantizerNegativeOneToOne();
    }
    else if ( standard != nil ) {
        *error = kTIOParserInvalidQuantizerError;
        return nil;
    }
    else if ( scale != nil && bias != nil ) {
        return TIODataDequantizerWithDequantization({
            .scale = scale.floatValue,
            .bias = bias.floatValue
        });
    }
    else {
        *error = kTIOParserInvalidQuantizerError;
        return nil;
    }
}

// MARK: - Image Parsing

TIOImageVolume TIOImageVolumeForShape(NSArray<NSNumber*> * _Nullable shape) {
    
    if ( shape == nil ) {
        NSLog(@"Expected input.shape array field in model.json, none found");
        return kTIOImageVolumeInvalid;
    }

    if ( !(shape.count == 3 || shape.count == 4) ) {
        NSLog(@"Expected shape with three elements or four if there is a dimension for the batch size, actual count is %lu", (unsigned long)shape.count);
        return kTIOImageVolumeInvalid;
    }

    if ( shape.count == 3 ) {
        return {
            .height = (int)shape[0].integerValue,
            .width = (int)shape[1].integerValue,
            .channels = (int)shape[2].integerValue
        };
    }
    if ( shape.count == 4 ) {
        // Batch is first dimension
        if ( shape[0].integerValue == -1 ) {
            return {
                .height = (int)shape[1].integerValue,
                .width = (int)shape[2].integerValue,
                .channels = (int)shape[3].integerValue
            };
        // Batch is last dimension
        } else if ( shape[3].integerValue == -1 ) {
            return {
                .height = (int)shape[0].integerValue,
                .width = (int)shape[1].integerValue,
                .channels = (int)shape[2].integerValue
            };
        } else {
            NSLog(@"Shape has four dimenions, indicating there is a dimension for the batch size, but neither the zeroeth index or third index has a value of -1");
            return kTIOImageVolumeInvalid;
        }
    }
    
    return kTIOImageVolumeInvalid;
}

OSType TIOPixelFormatForString(NSString * _Nullable string) {
    
    if ( string == nil ) {
        NSLog(@"Expected input.format string in model.json, none found");
        return TIOPixelFormatTypeInvalid;
    }
    else if ( [string isEqualToString:@"RGB"] ) {
        return kCVPixelFormatType_32ARGB;
    }
    else if ([string isEqualToString:@"BGR"] ) {
        return kCVPixelFormatType_32BGRA;
    }
    else {
        NSLog(@"expected input.format string to be 'RGB' or 'BGR', actual value is %@", string);
        return TIOPixelFormatTypeInvalid;
    }
}

TIOPixelNormalizer _Nullable TIOPixelNormalizerForDictionary(NSDictionary * _Nullable dict, NSError **error) {
    NSString *normalizerString = dict[@"standard"];
    NSNumber *scaleNumber = dict[@"scale"];
    NSDictionary *biases = dict[@"bias"];
    
    if ( dict == nil ) {
        return TIOPixelNormalizerNone();
    }
    
    if ( normalizerString != nil ) {
        if ( [normalizerString isEqualToString:@"[0,1]"] ) {
            return TIOPixelNormalizerZeroToOne();
        }
        else if ( [normalizerString isEqualToString:@"[-1,1]"] ) {
            return TIOPixelNormalizerNegativeOneToOne();
        }
        else {
            if ( error != nil ) { *error = kTIOParserInvalidPixelNormalizationError; }
            NSLog(@"Expected input.normalizer string to be '[0,1]' or '[-1,1]', actual value is %@", normalizerString);
            return nil;
        }
    }
    else if ( scaleNumber == nil && biases == nil ) {
        return TIOPixelNormalizerNone();
    }
    else {
        float_t scale = scaleNumber != nil
            ? [scaleNumber floatValue]
            : 1.0;
        float_t redBias = biases != nil
            ? [biases[@"r"] floatValue]
            : 0.0;
        float_t greenBias = biases != nil
            ? [biases[@"g"] floatValue]
            : 0.0;
        float_t blueBias = biases != nil
            ? [biases[@"b"] floatValue]
            : 0.0;
        
        TIOPixelNormalization normalization = {
            .scale = scale,
            .redBias = redBias,
            .greenBias = greenBias,
            .blueBias = blueBias
        };
        
        if ( (redBias == greenBias) && (redBias == blueBias) ) {
            return TIOPixelNormalizerSingleBias(normalization);
        } else {
            return TIOPixelNormalizerPerChannelBias(normalization);
        }
    }
}

TIOPixelDenormalizer _Nullable TIOPixelDenormalizerForDictionary(NSDictionary * _Nullable dict, NSError **error) {
    NSString *normalizerString = dict[@"standard"];
    NSNumber *scaleNumber = dict[@"scale"];
    NSDictionary *biases = dict[@"bias"];
    
    if ( dict == nil ) {
        return TIOPixelDenormalizerNone();
    }
    
    if ( normalizerString != nil ) {
        if ( [normalizerString isEqualToString:@"[0,1]"] ) {
            return TIOPixelDenormalizerZeroToOne();
        }
        else if ( [normalizerString isEqualToString:@"[-1,1]"] ) {
            return TIOPixelDenormalizerNegativeOneToOne();
        }
        else {
            if ( error != nil ) { *error = kTIOParserInvalidPixelDenormalizationError; }
            NSLog(@"Expected input.denormalizer string to be '[0,1]' or '[-1,1]', actual value is %@", normalizerString);
            return nil;
        }
    }
    else if ( scaleNumber == nil && biases == nil ) {
        return TIOPixelDenormalizerNone();
    }
    else {
        float_t scale = scaleNumber != nil
            ? [scaleNumber floatValue]
            : 1.0;
        float_t redBias = biases != nil
            ? [biases[@"r"] floatValue]
            : 0.0;
        float_t greenBias = biases != nil
            ? [biases[@"g"] floatValue]
            : 0.0;
        float_t blueBias = biases != nil
            ? [biases[@"b"] floatValue]
            : 0.0;
        
        TIOPixelNormalization normalization = {
            .scale = scale,
            .redBias = redBias,
            .greenBias = greenBias,
            .blueBias = blueBias
        };
        
        if ( (redBias == greenBias) && (redBias == blueBias) ) {
            return TIOPixelDenormalizerSingleBias(normalization);
        } else {
            return TIOPixelDenormalizerPerChannelBias(normalization);
        }
    }
}

// MARK: - Data Types

TIODataType TIODataTypeForString(NSString * _Nullable string) {
    string = string.lowercaseString;
    
    if ( string == nil ) {
        return TIODataTypeUnknown;
    } else if ( [string isEqualToString:@"uint8"]) {
        return TIODataTypeUInt8;
    } else if ( [string isEqualToString:@"float32"]) {
        return TIODataTypeFloat32;
    } else if ( [string isEqualToString:@"int32"]) {
        return TIODataTypeInt32;
    } else if ( [string isEqualToString:@"int64"]) {
        return TIODataTypeInt64;
    } else {
        NSLog(@"Uknown data type (dtype) encountered in layer: %@", string);
        return TIODataTypeUnknown;
    }
}

// MARK: - Pixel Format

const OSType TIOPixelFormatTypeInvalid = 'NULL';
