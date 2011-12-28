/*
    SwiffRenderer.m
    Copyright (c) 2011, musictheory.net, LLC.  All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:
        * Redistributions of source code must retain the above copyright
          notice, this list of conditions and the following disclaimer.
        * Redistributions in binary form must reproduce the above copyright
          notice, this list of conditions and the following disclaimer in the
          documentation and/or other materials provided with the distribution.
        * Neither the name of musictheory.net, LLC nor the names of its contributors
          may be used to endorse or promote products derived from this software
          without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
    ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL MUSICTHEORY.NET, LLC BE LIABLE FOR ANY
    DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
    (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
    ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/


#import "SwiffRenderer.h"

#import "SwiffBitmapDefinition.h"
#import "SwiffDynamicTextAttributes.h"
#import "SwiffDynamicTextDefinition.h"
#import "SwiffFontDefinition.h"
#import "SwiffFrame.h"
#import "SwiffMovie.h"
#import "SwiffGradient.h"
#import "SwiffLineStyle.h"
#import "SwiffFillStyle.h"
#import "SwiffPath.h"
#import "SwiffPlacedObject.h"
#import "SwiffPlacedDynamicText.h"
#import "SwiffShapeDefinition.h"
#import "SwiffStaticTextRecord.h"
#import "SwiffStaticTextDefinition.h"


struct _SwiffRenderer {
    SwiffMovie       *movie;
    NSArray          *placedObjects;
    CGFloat           hairlineWidth;
    CGFloat           hairlineWithFillWidth;
    CGAffineTransform baseAffineTransform;
    SwiffColor        tintColor;
    BOOL              hasBaseAffineTransform;
    BOOL              hasTintColor;
};


typedef struct _SwiffRenderState {
    SwiffMovie       *movie;
    CGContextRef      context;
    CGRect            clipBoundingBox;
    CGAffineTransform affineTransform;
    CFMutableArrayRef colorTransforms;
    CGFloat           hairlineWidth;
    CGFloat           hairlineWithFillWidth;
    CGFloat           tintRed;
    CGFloat           tintGreen;
    CGFloat           tintBlue;
    UInt16            clipDepth;
    BOOL              isBuildingClippingPath;
    BOOL              skipUntilClipDepth;
    BOOL              hasTintColor;
} SwiffRenderState;


static void sDrawPlacedObject(SwiffRenderState *state, SwiffPlacedObject *placedObject, BOOL applyColorTransform, BOOL applyAffineTransform);
static void sStopClipping(SwiffRenderState *state);


static void sStartClipping(SwiffRenderState *state, UInt16 clipDepth)
{
    if (state->clipDepth == 0) {
        CGContextRef context = state->context;

        CGContextSaveGState(context);
        CGContextClip(context);

        state->clipDepth = clipDepth;
    }
}


static void sStopClipping(SwiffRenderState *state)
{
    if (state->clipDepth) {
        CGContextRestoreGState(state->context);
        state->clipDepth = 0;
        state->skipUntilClipDepth = NO;
    }
}


static void sApplyTintColor(SwiffRenderState *state, SwiffColor *color)
{
    color->red   *= state->tintRed;
    color->green *= state->tintGreen;
    color->blue  *= state->tintBlue;
}


static void sPushColorTransform(SwiffRenderState *state, const SwiffColorTransform *transform)
{
    if (!state->colorTransforms) {
        state->colorTransforms = CFArrayCreateMutable(NULL, 0, NULL);
    }

    CFMutableArrayRef array = state->colorTransforms;
    CFArraySetValueAtIndex(array, CFArrayGetCount(array), transform);
}


static void sPopColorTransform(SwiffRenderState *state)
{
    CFMutableArrayRef array = state->colorTransforms;
    CFArrayRemoveValueAtIndex(array, CFArrayGetCount(array) - 1);
}


static void sApplyLineStyle(SwiffRenderState *state, SwiffLineStyle *style, CGFloat hairlineWidth)
{
    CGContextRef context = state->context;
    
    CGFloat    width    = [style width];
    CGLineJoin lineJoin = [style lineJoin];

    if (width == SwiffLineStyleHairlineWidth) {
        CGContextSetLineWidth(context, hairlineWidth);
    } else {
        CGContextSetLineWidth(context, width);
    }
    
    CGContextSetLineCap(context, [style startLineCap]);
    CGContextSetLineJoin(context, lineJoin);
    
    if (lineJoin == kCGLineJoinMiter) {
        CGContextSetMiterLimit(context, [style miterLimit]);
    }

    SwiffColor color = SwiffColorApplyColorTransformStack([style color], state->colorTransforms);
    if (state->hasTintColor) sApplyTintColor(state, &color);
    CGContextSetStrokeColor(context, (CGFloat *)&color);
}


static void sApplyFillStyle(SwiffRenderState *state, SwiffFillStyle *style)
{
    CGContextRef context = state->context;
   
    SwiffFillStyleType type = [style type];

    if (type == SwiffFillStyleTypeColor) {
        SwiffColor color = SwiffColorApplyColorTransformStack([style color], state->colorTransforms);
        if (state->hasTintColor) sApplyTintColor(state, &color);
        CGContextSetFillColor(context, (CGFloat *)&color);

    } else if ((type == SwiffFillStyleTypeLinearGradient) || (type == SwiffFillStyleTypeRadialGradient)) {
        CGContextSaveGState(context);
        CGContextEOClip(context);

        if (state->hasTintColor) {
            SwiffColorTransform tintAsTransform = {
                state->tintRed,
                state->tintGreen,
                state->tintBlue,
                1.0,
                0.0, 0.0, 0.0, 0.0
            };

            sPushColorTransform(state, &tintAsTransform);
        }

        CGGradientRef gradient = [[style gradient] copyCGGradientWithColorTransformStack:state->colorTransforms];

        if (state->hasTintColor) {
            sPopColorTransform(state);
        }

        CGGradientDrawingOptions options = (kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);

        if (type == SwiffFillStyleTypeLinearGradient) {
            // "All gradients are defined in a standard space called the gradient square. The gradient square is
            //  centered at (0,0), and extends from (-16384,-16384) to (16384,16384)." (Page 144)
            // 
            // 16384 twips = 819.2 points
            //
            CGPoint point1 = CGPointMake(-819.2,  819.2);
            CGPoint point2 = CGPointMake( 819.2,  819.2);
            
            CGAffineTransform t = [style gradientTransform];

            point1 = CGPointApplyAffineTransform(point1, t);
            point2 = CGPointApplyAffineTransform(point2, t);
        
            CGContextDrawLinearGradient(context, gradient, point1, point2, options);

        } else {
            CGAffineTransform t = [style gradientTransform];

            CGFloat radius = 819.2 * t.a;
            CGPoint centerPoint = CGPointMake(t.tx, t.ty);

            CGContextDrawRadialGradient(context, gradient, centerPoint, 0, centerPoint, radius, options);
        }
        
        CGGradientRelease(gradient);
        CGContextRestoreGState(context);

    } else if ((type >= SwiffFillStyleTypeRepeatingBitmap) && (type <= SwiffFillStyleTypeNonSmoothedClippedBitmap)) {
        SwiffBitmapDefinition *bitmapDefinition = [state->movie bitmapDefinitionWithLibraryID:[style bitmapID]];
        CGAffineTransform transform = [style bitmapTransform];

        BOOL shouldInterpolate = (type == SwiffFillStyleTypeRepeatingBitmap) || (type == SwiffFillStyleTypeClippedBitmap);
        BOOL shouldTile        = (type == SwiffFillStyleTypeRepeatingBitmap) || (type == SwiffFillStyleTypeNonSmoothedRepeatingBitmap);
        
        //!nyi: implement tiling
        (void)shouldTile;

        CGImageRef image = [bitmapDefinition CGImage];
        if (image) {
            CGContextSaveGState(context);
            CGContextConcatCTM(context, transform);
            
            CGContextClip(context);

            CGRect rect = CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image));
            
            CGContextTranslateCTM(context, 0, rect.size.height);
            CGContextScaleCTM(context, 1, -1);
            
            CGContextSetInterpolationQuality(context, shouldInterpolate ? kCGInterpolationDefault : kCGInterpolationNone);

            SwiffColor color = { 1.0, 1.0, 1.0, 1.0 };
            color = SwiffColorApplyColorTransformStack(color, state->colorTransforms);

            CGContextSetAlpha(context, color.alpha);
    
            CGContextDrawImage(context, rect, image);
            CGContextRestoreGState(context);
        }   
    }
}


static void sDrawSpriteDefinition(SwiffRenderState *state, SwiffSpriteDefinition *spriteDefinition)
{
    NSArray    *frames = [spriteDefinition frames];
    SwiffFrame *frame  = [frames count] ? [frames objectAtIndex:0] : nil;
    
    for (SwiffPlacedObject *po in [frame placedObjects]) {
        sDrawPlacedObject(state, po, YES, YES);
    }
}


static void sDrawShapeDefinition(SwiffRenderState *state, SwiffShapeDefinition *shapeDefinition)
{
    CGContextRef context = state->context;
    BOOL isBuildingClippingPath = state->isBuildingClippingPath;
    CGFloat hairlineWidth = state->hairlineWidth;

    for (SwiffPath *path in [shapeDefinition paths]) {
        SwiffLineStyle *lineStyle = [path lineStyle];
        SwiffFillStyle *fillStyle = [path fillStyle];

        if (isBuildingClippingPath) {
            if (!fillStyle) {
                continue;
            }

        } else {
            CGContextBeginPath(context);
        }

        CGFloat lineWidth = [lineStyle width];
        BOOL shouldRound  = (lineWidth == SwiffLineStyleHairlineWidth);
        BOOL shouldClose  = !lineStyle || [lineStyle closesStroke];

        // Prevent blurry lines when a/d are 1/-1 
        if ((lround(lineWidth) % 2) == 1 &&
            ((state->affineTransform.a == 1.0) || (state->affineTransform.a == -1.0)) &&
            ((state->affineTransform.d == 1.0) || (state->affineTransform.d == -1.0)))
        {
            shouldRound = YES;
        }

        BOOL hasPointTransform = NO;

        CGContextSaveGState(context);

        if (!lineStyle || [lineStyle scalesHorizontally] || [lineStyle scalesVertically]) {
            CGContextConcatCTM(context, state->affineTransform);
        } else {
            hasPointTransform = YES;
        }

        SwiffPathOperation *operations = [path operations];
        CGPoint *points   = [path points];
        BOOL     isDone   = (operations == nil);
        CGPoint  lastMove = { NAN, NAN };
        CGPoint  location = { NAN, NAN };

        CGFloat  roundScale, roundOffset;
        
        if (shouldRound) {
            if ([path useHairlineWithFillWidth] && state->hairlineWithFillWidth) {
                hairlineWidth = state->hairlineWithFillWidth;
            } else {
                hairlineWidth = state->hairlineWidth;
            }

            roundScale  = (1.0 / hairlineWidth);
            roundOffset = hairlineWidth / 2.0;
        }

        while (!isDone) {
            CGFloat  type    = *operations++;
            CGPoint  toPoint = *points++;

            if (hasPointTransform) {
                toPoint = CGPointApplyAffineTransform(toPoint, state->affineTransform);
            }

            if (shouldRound) {
                if (state->affineTransform.a < 0) {
                    toPoint.x = (ceil (toPoint.x * roundScale) / roundScale) - roundOffset;
                } else {
                    toPoint.x = (floor(toPoint.x * roundScale) / roundScale) + roundOffset;
                }
                
                if (state->affineTransform.d < 0) {
                    toPoint.y = (ceil (toPoint.y * roundScale) / roundScale) - roundOffset;
                } else {
                    toPoint.y = (floor(toPoint.y * roundScale) / roundScale) + roundOffset;
                }
            }

            if (type == SwiffPathOperationMove) {
                if (shouldClose && (lastMove.x == location.x) && (lastMove.y == location.y)) {
                    CGContextClosePath(context);
                }

                CGContextMoveToPoint(context, toPoint.x, toPoint.y);
                lastMove = toPoint;
                
            } else if (type == SwiffPathOperationLine) {
                CGContextAddLineToPoint(context, toPoint.x, toPoint.y);
            
            } else if (type == SwiffPathOperationCurve) {
                CGPoint controlPoint = *points++;
                
                if (hasPointTransform) {
                    controlPoint = CGPointApplyAffineTransform(controlPoint, state->affineTransform);
                }

                CGContextAddQuadCurveToPoint(context, controlPoint.x, controlPoint.y, toPoint.x, toPoint.y);
            
            } else {
                isDone = YES;
            }

            location = toPoint;
        }

        if (shouldClose && (lastMove.x == location.x) && (lastMove.y == location.y)) {
            CGContextClosePath(context);
        }

        BOOL hasStroke = NO;
        BOOL hasFill   = NO;

        if (!isBuildingClippingPath) {
            if (lineWidth > 0) {
                sApplyLineStyle(state, lineStyle, hairlineWidth);
                hasStroke = YES;
            }
            
            if (fillStyle) {
                sApplyFillStyle(state, fillStyle);
                hasFill = ([fillStyle type] == SwiffFillStyleTypeColor);
            }
            
            if (hasStroke || hasFill) {
                CGPathDrawingMode mode;
                
                if      (hasStroke && hasFill) mode = kCGPathFillStroke;
                else if (hasStroke)            mode = kCGPathStroke;
                else                           mode = kCGPathFill;
                
                CGContextDrawPath(context, mode);
            }
        }

        CGContextRestoreGState(context);
    }
}


static void sDrawStaticTextDefinition(SwiffRenderState *state, SwiffStaticTextDefinition *staticTextDefinition)
{
    SwiffFontDefinition *font = nil;
    CGPathRef *glyphPaths = NULL;

    CGContextRef context = state->context;
    CGPoint offset = CGPointZero;
    CGFloat aWithMultiplier = state->affineTransform.a;
    CGFloat dWithMultiplier = state->affineTransform.d;

    CGContextSaveGState(context);

    for (SwiffStaticTextRecord *record in [staticTextDefinition textRecords]) {
        NSInteger glyphEntriesCount = [record glyphEntriesCount];
        SwiffStaticTextRecordGlyphEntry *glyphEntries = [record glyphEntries];
        
        CGFloat advance = 0; 

        if ([record hasFont]) {
            font = [state->movie fontDefinitionWithLibraryID:[record fontID]];
            glyphPaths = [font glyphPaths];

            CGFloat multiplier = (1.0 / SwiffFontEmSquareHeight) * [record textHeight];
            aWithMultiplier = state->affineTransform.a * multiplier;
            dWithMultiplier = state->affineTransform.d * multiplier;
        }
        
        if ([record hasColor]) {
            CGContextSetFillColor(context, (CGFloat *)[record colorPointer]);
        }
        
        if ([record hasXOffset]) {
            offset.x = [record xOffset];
        }

        if ([record hasYOffset]) {
            offset.y = [record yOffset];
        }

        if (glyphPaths && glyphEntries) {
            for (NSInteger i = 0; i < glyphEntriesCount; i++) {
                SwiffStaticTextRecordGlyphEntry entry = glyphEntries[i];

                CGAffineTransform savedTransform = state->affineTransform;

                state->affineTransform = CGAffineTransformTranslate(state->affineTransform, offset.x + advance, offset.y);
                state->affineTransform.a = aWithMultiplier;
                state->affineTransform.d = dWithMultiplier;

                CGContextSaveGState(context);
                CGContextConcatCTM(context, state->affineTransform);
                CGContextAddPath(context, glyphPaths[entry.index]);
                CGContextRestoreGState(context);

                advance += entry.advance;

                state->affineTransform = savedTransform;
            }
        }
        
        CGContextDrawPath(context, kCGPathFill);

        offset.x += advance;
    }

    CGContextRestoreGState(context);
}


static void sDrawPlacedDynamicText(SwiffRenderState *state, SwiffPlacedDynamicText *placedDynamicText)
{
    CFAttributedStringRef as = [placedDynamicText attributedText];
    SwiffDynamicTextDefinition *definition = [placedDynamicText definition];
    CGRect rect = [definition bounds];

    CGContextRef context = state->context;
    CTFramesetterRef framesetter = as ? CTFramesetterCreateWithAttributedString(as) : NULL;
    
    if (framesetter) {
        CGPathRef  path  = CGPathCreateWithRect(CGRectMake(0, 0, rect.size.width, rect.size.height), NULL);
        CTFrameRef frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, NULL);

        if (frame) {
            CGContextSaveGState(context);

            CGContextTranslateCTM(context, rect.origin.x, rect.origin.y);

            CGContextConcatCTM(context, state->affineTransform);
            CGContextTranslateCTM(context, 0, rect.size.height);
            CGContextScaleCTM(context, 1, -1);
            
            NSInteger i;
            CFArrayRef lines = CTFrameGetLines(frame);
            CFIndex linesCount = CFArrayGetCount(lines);
            CGPoint *origins = malloc(sizeof(CGPoint) * linesCount);

            CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), origins);

            for (i = 0; i < linesCount; i++) {
                CTLineRef line = CFArrayGetValueAtIndex(lines, i);
                CGPoint origin = origins[i];

                CFRange rangeOfLine = CTLineGetStringRange(line);

                origin.y -= SwiffTextGetMaximumVerticalOffset(as, rangeOfLine);

                CGContextSetTextPosition(context, origin.x, origin.y);
                
                CTLineDraw(line, context);
            }
            
            free(origins);
            
            CGContextFlush(context);
            CGContextRestoreGState(context);

            CFRelease(frame);
        }
        
        if (path) CFRelease(path);
        CFRelease(framesetter);
    }
}


static void sDrawPlacedObject(SwiffRenderState *state, SwiffPlacedObject *placedObject, BOOL applyColorTransform, BOOL applyAffineTransform)
{
    UInt16 placedObjectClipDepth = placedObject->m_additional ? [placedObject clipDepth] : 0;
    UInt16 placedObjectDepth     = placedObject->m_depth;
    BOOL   placedObjectIsHidden  = placedObject->m_additional ? [placedObject isHidden] : NO;

    // If we are in a clipping mask...
    if (state->clipDepth) {
    
        // Stop clipping if the depth is higher than the clipDepth
        if (placedObjectDepth > state->clipDepth) {
            sStopClipping(state);
        }
        
        // Our clipping mask layer was hidden (or not in the clip bounding box).  We can safely skip drawing this layer
        if (state->skipUntilClipDepth) {
            return;
        }
    }

    // The current depth starts a clipping mask
    if (placedObjectClipDepth) {
        state->isBuildingClippingPath = YES;
        state->skipUntilClipDepth = YES;
    }

    // Bail out if placedObject is hidden
    if (placedObjectIsHidden) {
        return;
    }

    id<SwiffDefinition> definition = SwiffMovieGetDefinition(state->movie, [placedObject libraryID]);

    CGAffineTransform newTransform = CGAffineTransformConcat([placedObject affineTransform], state->affineTransform);

    // Bail out if renderBounds is not in the clipBoundingBox
    CGRect renderBounds = CGRectApplyAffineTransform([definition renderBounds], newTransform);
    if (!CGRectIntersectsRect(renderBounds, state->clipBoundingBox)) {
        return;
    }

    CGAffineTransform savedTransform;

    if (applyAffineTransform) {
        savedTransform = state->affineTransform;
        state->affineTransform = newTransform;
    }

    BOOL needsColorTransformPop = NO;

    if (applyColorTransform) {
        BOOL hasColorTransform = [placedObject hasColorTransform];

        if (hasColorTransform) {
            sPushColorTransform(state, [placedObject colorTransformPointer]);
            needsColorTransformPop = YES;
        }
    }

    if ([definition isKindOfClass:[SwiffDynamicTextDefinition class]]) {
        if ([placedObject isKindOfClass:[SwiffPlacedDynamicText class]]) {
            sDrawPlacedDynamicText(state, (SwiffPlacedDynamicText *)placedObject);
        }

    } else if ([definition isKindOfClass:[SwiffShapeDefinition class]]) {
        sDrawShapeDefinition(state, (SwiffShapeDefinition *)definition);

    } else if ([definition isKindOfClass:[SwiffSpriteDefinition class]]) {
        sDrawSpriteDefinition(state, (SwiffSpriteDefinition *)definition);

    } else if ([definition isKindOfClass:[SwiffStaticTextDefinition class]]) {
        sDrawStaticTextDefinition(state, (SwiffStaticTextDefinition *)definition);
    }

    if (needsColorTransformPop) {
        sPopColorTransform(state);
    }

    if (applyAffineTransform) {
        state->affineTransform = savedTransform;
    }

    if (placedObjectClipDepth) {
        sStartClipping(state, placedObjectClipDepth);
        state->isBuildingClippingPath = NO;
        state->skipUntilClipDepth = NO;
    }
}


#pragma mark -
#pragma mark Public Methods

SwiffRenderer *SwiffRendererCreate(SwiffMovie *movie)
{
    SwiffRenderer *renderer = calloc(sizeof(SwiffRenderer), 1);

    renderer->movie = [movie retain];
    
    return renderer;
}


void SwiffRendererFree(SwiffRenderer *renderer)
{
    [renderer->movie release];
    renderer->movie = nil;

    [renderer->placedObjects release];
    renderer->placedObjects = nil;
    
    free(renderer);
}


void SwiffRendererRender(SwiffRenderer *renderer, CGContextRef context)
{
    SwiffRenderState state;
    memset(&state, 0, sizeof(SwiffRenderState));

    state.movie   = renderer->movie;
    state.context = context;

    if (renderer->hasTintColor && (renderer->tintColor.alpha > 0)) {
        state.tintRed   = (renderer->tintColor.red   * renderer->tintColor.alpha);
        state.tintGreen = (renderer->tintColor.green * renderer->tintColor.alpha);
        state.tintBlue  = (renderer->tintColor.blue  * renderer->tintColor.alpha);
        state.hasTintColor = YES;
    }
    
    if (renderer->hasBaseAffineTransform) {
        state.affineTransform = renderer->baseAffineTransform;
    } else {
        state.affineTransform = CGAffineTransformIdentity;
    }

    state.hairlineWidth = renderer->hairlineWidth ? renderer->hairlineWidth : 1.0;
    state.hairlineWithFillWidth = renderer->hairlineWithFillWidth;
    
    state.clipBoundingBox = CGContextGetClipBoundingBox(context);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextSetFillColorSpace(context, colorSpace);
    CGContextSetStrokeColorSpace(context, colorSpace);

    CGColorSpaceRelease(colorSpace);

    for (SwiffPlacedObject *object in renderer->placedObjects) {
        sDrawPlacedObject(&state, object, YES, YES);
    }
    
    state.movie   = nil;
    state.context = NULL;
    
    if (state.colorTransforms) {
        CFRelease(state.colorTransforms);
    }

    sStopClipping(&state);
}


void SwiffRendererSetPlacedObjects(SwiffRenderer *renderer, NSArray *placedObjects)
{
    if (placedObjects != renderer->placedObjects) {
        [renderer->placedObjects release];
        renderer->placedObjects = [placedObjects retain];
    }
}


NSArray *SwiffRendererGetPlacedObjects(SwiffRenderer *renderer)
{
    return renderer->placedObjects;
}


void SwiffRendererSetBaseAffineTransform(SwiffRenderer *renderer, CGAffineTransform *transform)
{
    if (transform && !CGAffineTransformIsIdentity(*transform)) {
        renderer->baseAffineTransform = *transform;
        renderer->hasBaseAffineTransform = YES;
    } else {
        renderer->hasBaseAffineTransform = NO;
    }
}


CGAffineTransform *SwiffRendererGetBaseAffineTransform(SwiffRenderer *renderer)
{
    if (renderer->hasBaseAffineTransform) {
        return &renderer->baseAffineTransform;
    } else {
        return NULL;
    }
}


void SwiffRendererSetTintColor(SwiffRenderer *renderer, SwiffColor *tintColor)
{
    if (tintColor && (tintColor->alpha > 0)) {
        renderer->tintColor = *tintColor;
        renderer->hasTintColor = YES;
    } else {
        renderer->hasTintColor = NO;
    }
}


SwiffColor *SwiffRendererGetTintColor(SwiffRenderer *renderer)
{
    if (renderer->hasTintColor) {
        return &renderer->tintColor;
    } else {
        return NULL;
    }
}


void SwiffRendererSetHairlineWidth(SwiffRenderer *renderer, CGFloat hairlineWidth)
{
    renderer->hairlineWidth = hairlineWidth;
}


CGFloat SwiffRendererGetHairlineWidth(SwiffRenderer *renderer)
{
    return renderer->hairlineWidth;
}


void SwiffRendererSetHairlineWithFillWidth(SwiffRenderer *renderer, CGFloat hairlineWidth)
{
    renderer->hairlineWithFillWidth = hairlineWidth;
}


CGFloat SwiffRendererGetHairlineWithFillWidth(SwiffRenderer *renderer)
{
    return renderer->hairlineWithFillWidth;
}
