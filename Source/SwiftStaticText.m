/*
    SwiftStaticText.m
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

#import "SwiftStaticText.h"

#import "SwiftParser.h"
#import "SwiftTextRecord.h"

@implementation SwiftStaticText

- (id) initWithParser:(SwiftParser *)parser tag:(SwiftTag)tag version:(NSInteger)version
{
    if ((self = [super init])) {
        UInt16 libraryID;
        SwiftParserReadUInt16(parser, &libraryID);
        m_libraryID = libraryID;
        
        SwiftParserReadRect(parser,   &m_bounds);
        SwiftParserReadMatrix(parser, &m_affineTransform);

        UInt8 glyphBits, advanceBits;
        SwiftParserReadUInt8(parser, &glyphBits);
        SwiftParserReadUInt8(parser, &advanceBits);
    
        m_textRecords = [[SwiftTextRecord textRecordArrayWithParser:parser tag:tag version:version glyphBits:glyphBits advanceBits:advanceBits] retain];
    }
    
    return self;
}

- (void) dealloc
{
    [m_textRecords release];
    m_textRecords = nil;

    [super dealloc];
}

- (BOOL) hasEdgeBounds { return NO; }
- (CGRect) edgeBounds { return CGRectZero; }


@synthesize libraryID = m_libraryID,
            bounds    = m_bounds;

@end