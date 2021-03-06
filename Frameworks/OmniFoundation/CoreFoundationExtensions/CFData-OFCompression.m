// Copyright 1997-2010 Omni Development, Inc.  All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import <OmniFoundation/CFData-OFCompression.h>

#import <OmniFoundation/OFErrors.h>
#import <OmniFoundation/CFData-OFFileIO.h>
#import <OmniFoundation/OFReadWriteFileBuffer.h>
#import <OmniBase/NSError-OBExtensions.h>
#import <OmniBase/assertions.h>
#import <OmniBase/rcsid.h>
#import <Foundation/NSBundle.h>
#import <Foundation/NSData.h>
#import <Foundation/NSString.h>
#import <OmniBase/OBUtilities.h>
#import <bzlib.h>
#import <zlib.h>

RCS_ID("$Id$")

/*" Compression/decompression.
 We support both bz2 and gzip compression.  We default to using gzip; bz2 compresses better, but its worst-case performance is much, much worse (and we don't want to make users wait when saving).
 "*/

static inline Boolean _OFMightBeBzipCompressedData(const unsigned char *bytes, NSUInteger length)
{
    return (length >= 2 && bytes[0] == 'B' && bytes[1] == 'Z');
}

static inline Boolean _OFMightBeGzipCompressedData(const unsigned char *bytes, NSUInteger length)
{
    return (length >= 10 && bytes[0] == 0x1F && bytes[1] == 0x8B);
}

/*" Returns TRUE if the receiver looks like it might be compressed data that -decompressedData can handle.  Note that if this returns TRUE, it merely looks like the receiver is compressed, not that it is.  This is a simply intended to be a quick check to filter out obviously uncompressed data. "*/
Boolean OFDataMightBeCompressed(CFDataRef data)
{
    const unsigned char *bytes = CFDataGetBytePtr(data);
    NSUInteger length = CFDataGetLength(data);
    return _OFMightBeGzipCompressedData(bytes, length) || _OFMightBeBzipCompressedData(bytes, length);
}

CFDataRef OFDataCreateCompressedData(CFDataRef data, CFErrorRef *outError)
{
    return OFDataCreateCompressedGzipData(data, TRUE, 9, outError);
}

static void *_OFCompressionError(CFErrorRef *outError, NSInteger code, NSString *description, NSString *reason)
{
    OBPRECONDITION(description); // else the arg list below will be prematurely nil terminated
    
    if (outError) {
        // CFErrorRef is toll-free bridged; but CF APIs return retained instances.
        OBErrorWithInfo((NSError **)outError, OFUnableToDecompressData, NSLocalizedDescriptionKey, description, NSLocalizedFailureReasonErrorKey, reason, nil);
        CFRetain(*outError); // OBError creates an autoreleased instance, but this is a CF API
    }
    
    return NULL;
}

CFDataRef OFDataCreateDecompressedData(CFAllocatorRef decompressedDataAllocator, CFDataRef data, CFErrorRef *outError)
{
    const uint8_t *initial = CFDataGetBytePtr(data);
    NSUInteger dataLength = CFDataGetLength(data);
    if (_OFMightBeBzipCompressedData(initial, dataLength))
        return OFDataCreateDecompressedBzip2Data(decompressedDataAllocator, data, outError);
    
    if (_OFMightBeGzipCompressedData(initial, dataLength))
        return OFDataCreateDecompressedGzip2Data(decompressedDataAllocator, data, outError);
    
    return _OFCompressionError(outError, OFUnableToDecompressData,
                               NSLocalizedStringFromTableInBundle(@"Unable to decompress data.", @"OmniFoundation", OMNI_BUNDLE, @"decompression error description"),
                               NSLocalizedStringFromTableInBundle(@"unrecognized compression format.", @"OmniFoundation", OMNI_BUNDLE, @"decompression error reason"));
}


/*" Compresses the receiver using the bz2 library algorithm and returns the compressed data.   The compressed data is a full bz2 file, not just a headerless compressed blob.  This is very useful if you are including this compressed data in a larger file wrapper and want users to be able to read it with standard tools. "*/
CFDataRef OFDataCreateCompressedBzip2Data(CFDataRef data, CFErrorRef *outError)
{
    CFMutableDataRef output = CFDataCreateMutable(NULL, 0);
    
    FILE *dataFile = OFDataCreateReadWriteStandardIOFile(output, outError);
    if (!dataFile) {
        CFRelease(output);
        return NULL;
    }
    
    int err;
    BZFILE *bzFile = BZ2_bzWriteOpen(&err, dataFile,
                                     6,  // blockSize100k from 1-9, 9 best compression, slowest speed
                                     0,  // verbosity
                                     0); // workFactor, 0-250, 0==default of 30
    if (!bzFile) {
        CFRelease(output);
        fclose(dataFile);
        return _OFCompressionError(outError, OFUnableToCompressData,
                                   NSLocalizedStringFromTableInBundle(@"Unable to initialize compression", @"OmniFoundation", OMNI_BUNDLE, @"compression error description"), nil);
    }
    
    // BZ2_bzWrite fails with BZ_PARAM_ERROR when passed length==0; allow compressing empty data by just not doing a write.
    NSUInteger length = CFDataGetLength(data);
    if (length) {
        OBASSERT(length < INT_MAX); // Need to loop for large datas.
        
        BZ2_bzWrite(&err, bzFile, (void  *)CFDataGetBytePtr(data), (int)length);
        if (err != BZ_OK) {
            // Create exception before closing file since we read from the file
            NSString *reason = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"bzip2 library returned error code %d when writing data. %s.", @"OmniFoundation", OMNI_BUNDLE, @"compression error reason"), err, BZ2_bzerror(bzFile, &err)];
            fclose(dataFile);
            BZ2_bzWriteClose(&err, bzFile, 0, NULL, NULL);
            CFRelease(output);
            return _OFCompressionError(outError, OFUnableToCompressData,
                                       NSLocalizedStringFromTableInBundle(@"Unable to compress data.", @"OmniFoundation", OMNI_BUNDLE, @"compression error description"), reason);
        }
    }
    
    BZ2_bzWriteClose(&err, bzFile, 0, NULL, NULL);
    if (err != BZ_OK) {
        NSString *reason = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"bzip2 library returned error code %d when finishing compression. %s.", @"OmniFoundation", OMNI_BUNDLE, @"compression error reason"), err, BZ2_bzerror(bzFile, &err)];
        fclose(dataFile);
        CFRelease(output);
        return _OFCompressionError(outError, OFUnableToCompressData,
                                   NSLocalizedStringFromTableInBundle(@"Unable to compress data.", @"OmniFoundation", OMNI_BUNDLE, @"compression error description"), reason);
    }
    
    fclose(dataFile);
    return output;
}

/*" Decompresses the receiver using the bz2 library algorithm and returns the decompressed data.   The receiver must represent a full bz2 file, not just a headerless compressed blob.  This is very useful if you are including this compressed data in a larger file wrapper and want users to be able to read it with standard tools.  Returns an error if the receiver does not contain valid compressed data. "*/
CFDataRef OFDataCreateDecompressedBzip2Data(CFAllocatorRef decompressedDataAllocator, CFDataRef data, CFErrorRef *outError)
{
    FILE *dataFile = OFDataCreateReadOnlyStandardIOFile(data, outError);
    if (!dataFile)
        return NULL;
    
    int err;
    BZFILE *bzFile = BZ2_bzReadOpen(&err, dataFile,
                                    CFDataGetLength(data) < 4*1024,  // small; set to 1 for things that are 'small' to use less memory
                                    0,  // verbosity
                                    NULL, 0); // unused
    if (!bzFile) {
        fclose(dataFile);
        return _OFCompressionError(outError, OFUnableToDecompressData,
                                   NSLocalizedStringFromTableInBundle(@"Unable to initialize decompression", @"OmniFoundation", OMNI_BUNDLE, @"decompression error description"), nil);
    }
    
    size_t pageSize  = NSPageSize();
    NSUInteger totalBytesRead = 0;
    CFMutableDataRef output = CFDataCreateMutable(decompressedDataAllocator, 0);
    
    do {
        NSUInteger avail = CFDataGetLength(output) - totalBytesRead;
        if (avail < pageSize) {
            CFDataSetLength(output, CFDataGetLength(output) + 4*pageSize);
            avail = CFDataGetLength(output) - totalBytesRead;
        }
        void *ptr = CFDataGetMutableBytePtr(output) + totalBytesRead;
        
        
        OBASSERT(avail < INT_MAX); // Need to loop to handl large files
        int bytesRead = BZ2_bzRead(&err, bzFile, ptr, (int)avail);
        if (err != BZ_OK && err != BZ_STREAM_END) {
            // Create exception before closing file since we read from the file
            NSString *reason = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"bzip2 library returned error code %d when reading data. %s.", @"OmniFoundation", OMNI_BUNDLE, @"decompression error reason"), err, BZ2_bzerror(bzFile, &err)];
            fclose(dataFile);
            BZ2_bzReadClose(&err, bzFile);
            CFRelease(output);
            return _OFCompressionError(outError, OFUnableToDecompressData,
                                       NSLocalizedStringFromTableInBundle(@"Unable to decompress data.", @"OmniFoundation", OMNI_BUNDLE, @"decompression error description"), reason);
        }
        
        totalBytesRead += bytesRead;
    } while (err != BZ_STREAM_END);
    
    CFDataSetLength(output, totalBytesRead);
    
    BZ2_bzReadClose(&err, bzFile);
    fclose(dataFile);
    
    return output;
}

/* Support for RFC 1952 gzip formatting. This is a simple wrapper around the data produced by zlib. */

#define OF_ZLIB_BUFFER_SIZE (2 * 64 * 1024)

static CFMutableDataRef makeRFC1952MemberHeader(time_t modtime,
                                                NSString *orig_filename,
                                                NSString *file_comment,
                                                Boolean withCRC16,
                                                Boolean isText,
                                                u_int8_t xfl)
{
    NSData *filename_bytes, *comment_bytes;
    
    if (orig_filename)
        filename_bytes = [orig_filename dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
    else
        filename_bytes = nil;
    if (file_comment)
        comment_bytes = [file_comment dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
    else
        comment_bytes = nil;
    
    /* Allocate the result buffer */
    CFMutableDataRef result = CFDataCreateMutable(NULL, 0);
    CFDataSetLength(result,
                    10 +
                    (filename_bytes? [filename_bytes length] + 1 : 0) +
                    (comment_bytes? [comment_bytes length] + 1 : 0) +
                    (withCRC16 ? 2 : 0));
    
    u_int8_t *header = CFDataGetMutableBytePtr(result);
    
    /* GZIP file magic */
    header[0] = 0x1F;
    header[1] = 0x8B;
    
    /* Indicates use of the GZIP compression method */
    header[2] = Z_DEFLATED;
    
    /* Flag field #1 */
    header[3] = (isText? 1 : 0) | (withCRC16? 2 : 0) | (filename_bytes? 8 : 0) | (comment_bytes? 16 : 0);
    
    /* Modification time stamp */
    header[4] = ( modtime & 0x000000FF );
    header[5] = ( modtime & 0x0000FF00 ) >> 8;
    header[6] = ( modtime & 0x00FF0000 ) >> 16;
    header[7] = ( modtime & 0xFF000000 ) >> 24;
    
    /* Indicates file was written on a Unixlike system; we're being more Unixy than traditional-Mac-like */
    header[8] = 3;
    
    /* Flag field #2 */
    /* The XFLAG field is documented to have some bits set according to the compression level used by the compressor, but nobody actually reads it; it's not necessary to decompress the data, and RFC1952 doesn't really specify when each bit should be set anyway. So we don't worry about it overmuch. */    
    header[9] = xfl;
    
    /* Initialize the header CRC */
    uLong headerCRC = crc32(0L, Z_NULL, 0);
    
    /* Update the CRC as we go */
    headerCRC = crc32(headerCRC, header, 10);
    header += 10;
    
    /* Filename, if we have one, with terminating NUL */
    if (filename_bytes) {
        NSUInteger length = [filename_bytes length];
        OBASSERT(length < INT_MAX);
        
        [filename_bytes getBytes:header];
        header[length] = (char)0;
        headerCRC = crc32(headerCRC, header, (int)length+1);
        header += length+1;
    }
    
    /* File comment, if we have one, with terminating NUL */
    if (comment_bytes) {
        NSUInteger length = [comment_bytes length];
        OBASSERT(length < INT_MAX);

        [comment_bytes getBytes:header];
        header[length] = (char)0;
        headerCRC = crc32(headerCRC, header, (int)length+1);
        header += length+1;
    }
    
    /* Header CRC */
    if (withCRC16) {
        header[0] = ( headerCRC & 0x00FF );
        header[1] = ( headerCRC & 0xFF00 ) >> 8;
        //header += 2; clang hates the dead increment.
    }
    
    OBPOSTCONDITION( (CFIndex)((char *)header - (char *)CFDataGetBytePtr(result)) == CFDataGetLength(result) );
    
    return result;
}

static Boolean readNullTerminatedString(FILE *fp,
                                        NSStringEncoding encoding,
                                        NSString **into,
                                        uLong *runningCRC)
{
    CFMutableDataRef buffer;
    int ch;
    
    buffer = CFDataCreateMutable(kCFAllocatorDefault, 0);
    
    do {
        UInt8 chBuf[1];
        
        ch = getc(fp);
        if (ch == EOF) {
            CFRelease(buffer);
            return FALSE;
        }
        
        chBuf[0] = ch;
        CFDataAppendBytes(buffer, chBuf, 1);
    } while (ch != 0);
    
    NSUInteger bufferSize = CFDataGetLength(buffer);
    OBASSERT(bufferSize < INT_MAX);
    
    *runningCRC = crc32(*runningCRC, CFDataGetBytePtr(buffer), (int)bufferSize);
    
    if (into) {
        *into = [[[NSString alloc] initWithData:(NSData *)buffer encoding:encoding] autorelease];
    }
    
    CFRelease(buffer);
    return TRUE;
}


static Boolean checkRFC1952MemberHeader(FILE *fp,
                                        NSString **orig_filename,
                                        NSString **file_comment,
                                        Boolean *isText)
{
    u_int8_t header[10];
    size_t count;
    uLong runningCRC;
    
    count = fread(header, 1, 10, fp);
    if (count != 10)
        return FALSE;
    
    /* File magic */
    if (header[0] != 0x1F || header[1] != 0x8B)
        return FALSE;
    
    /* Compression algorithm: only Z_DEFLATED is valid */
    if (header[2] != Z_DEFLATED)
        return FALSE;
    
    /* Flags field */
    if (isText)
        *isText = ( header[3] & 1 ) ? TRUE : FALSE;
    
    /* Ignore modification time, XFL, and OS fields for now */
    
    runningCRC = crc32( crc32(0L, NULL, 0), header, 10 );
    
    /* We don't handle the FEXTRA field, which means we're not actually RFC1952-conformant. It's pretty rare, but we really should at least skip it. TODO. */
    if (header[3] & 0x04)
        return FALSE;
    
    /* Skip/read the filename. */
    if (header[3] & 0x08) {
        if (!readNullTerminatedString(fp, NSISOLatin1StringEncoding, orig_filename, &runningCRC))
            return FALSE;
    }
    
    /* Skip/read the file comment. */
    if (header[3] & 0x10) {
        if (!readNullTerminatedString(fp, NSISOLatin1StringEncoding, file_comment, &runningCRC))
            return FALSE;
    }
    
    /* Verify the CRC, if present. */
    if (header[3] & 0x02) {
        u_int8_t crc_buffer[2];
        unsigned storedCRC;
        
        if (fread(crc_buffer, 1, 2, fp) != 2)
            return FALSE;
        storedCRC = ( (unsigned)crc_buffer[0] ) | ( 256 * (unsigned)crc_buffer[1] );
        if (storedCRC != ( runningCRC & 0xFFFF ))
            return FALSE;
    }
    
    /* We've successfuly run the gauntlet. */
    return TRUE;
}


static Boolean OFZlibError(Boolean compressing, NSString *reason, int rc, z_stream *state, CFErrorRef *outError)
{
    NSString *description = compressing ? NSLocalizedStringFromTableInBundle(@"Unable to compress data.", @"OmniFoundation", OMNI_BUNDLE, @"compression error description") : NSLocalizedStringFromTableInBundle(@"Unable to decompress data.", @"OmniFoundation", OMNI_BUNDLE, @"decompression error description");

    if (!reason) {
        if (state && state->msg) {
            reason = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"zlib returned error code %d. %s.", @"OmniFoundation", OMNI_BUNDLE, @"zlib error reason"), rc, state->msg];
        } else {
            reason = [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"zlib returned error code %d.", @"OmniFoundation", OMNI_BUNDLE, @"zlib error reason"), rc];
        }
    }
    _OFCompressionError(outError, compressing ? OFUnableToCompressData : OFUnableToDecompressData, description, reason);
    return FALSE;
}

static void writeLE32(u_int32_t le32, FILE *fp)
{
    putc( (le32 & 0x000000FF)      , fp );
    putc( (le32 & 0x0000FF00) >>  8, fp );
    putc( (le32 & 0x00FF0000) >> 16, fp );
    putc( (le32 & 0xFF000000) >> 24, fp );
}

static u_int32_t unpackLE32(const u_int8_t *from)
{
    return ( (u_int32_t)from[0] ) |
    ( (u_int32_t)from[1] << 8 ) |
    ( (u_int32_t)from[2] << 16 ) |
    ( (u_int32_t)from[3] << 24 );
}

static Boolean handleRFC1952MemberBody(FILE *fp,
                                       CFDataRef data,
                                       NSRange sourceRange,
                                       int compressionLevel,
                                       Boolean withTrailer,
                                       Boolean compressing,
                                       CFErrorRef *outError)
{
    z_stream compressionState;
    
    uLong dataCRC = crc32(0L, Z_NULL, 0);
    
    if (compressionLevel < 0)
        compressionLevel = Z_DEFAULT_COMPRESSION;
    bzero(&compressionState, sizeof(compressionState));

    int rc;
    if (compressing) {
        /* Annoyingly underdocumented parameter: must pass windowBits = -MAX_WBITS to suppress the zlib header. */
        rc = deflateInit2(&compressionState, compressionLevel,
                          Z_DEFLATED, -MAX_WBITS, 9, Z_DEFAULT_STRATEGY);
        /* compressionState.data_type = dataType; */
    } else {
        rc = inflateInit2(&compressionState, -MAX_WBITS);
    }
    if (rc != Z_OK)
        return OFZlibError(compressing, nil, rc, &compressionState, outError);
    
    unsigned outputBufferSize = OF_ZLIB_BUFFER_SIZE;
    Bytef *outputBuffer = malloc(outputBufferSize);
    
    NSUInteger sourceLength = sourceRange.length;
    OBASSERT(sourceLength < INT_MAX);
    
    compressionState.next_in = (Bytef *)CFDataGetBytePtr(data) + sourceRange.location;
    compressionState.avail_in = (int)sourceLength;
    if (withTrailer && !compressing) {
        /* Subtract 8 bytes for the CRC and length which are stored after the compressed data. */
        if (sourceRange.length < 8) {
            deflateEnd(&compressionState);
            free(outputBuffer);
            return OFZlibError(compressing, @"zlib stream is too short", 0, NULL, outError);
        }
    }
    
    for(;;) {
        compressionState.next_out = outputBuffer;
        compressionState.avail_out = outputBufferSize;
        // printf("before: in = %u @ %p, out = %u @ %p\n", compressionState.avail_in, compressionState.next_in, compressionState.avail_out, compressionState.next_out);
        if (compressing) {
            const Bytef *last_in = compressionState.next_in;
            rc = deflate(&compressionState, Z_FINISH);
            if (compressionState.next_in > last_in) {
                NSUInteger crcLen = compressionState.next_in - last_in;
                OBASSERT(crcLen < UINT32_MAX);
                dataCRC = crc32(dataCRC, last_in, (uint32_t)crcLen);
            }
        } else {
            rc = inflate(&compressionState, Z_SYNC_FLUSH);
            if (compressionState.next_out > outputBuffer) {
                NSUInteger crcLen = compressionState.next_out - outputBuffer;
                OBASSERT(crcLen < UINT32_MAX);
                dataCRC = crc32(dataCRC, outputBuffer, (uint32_t)crcLen);
            }
        }
        // printf("after : in = %u @ %p, out = %u @ %p, ok = %d\n", compressionState.avail_in, compressionState.next_in, compressionState.avail_out, compressionState.next_out, ok);
        if (compressionState.next_out > outputBuffer)
            fwrite(outputBuffer, compressionState.next_out - outputBuffer, 1, fp);
        if (rc == Z_STREAM_END)
            break;
        else if (rc != Z_OK) {
            OFZlibError(compressing, nil, rc, &compressionState, outError);
            deflateEnd(&compressionState);
            free(outputBuffer);
            return FALSE;
        }
    }

    if (compressing) {
#ifdef OMNI_ASSERTIONS_ON
        rc = 
#endif
        deflateEnd(&compressionState);
    } else {
#ifdef OMNI_ASSERTIONS_ON
        rc = 
#endif
        inflateEnd(&compressionState);
    }
    OBASSERT(rc == Z_OK);
    if (compressing || !withTrailer) {
        OBASSERT(compressionState.avail_in == 0);
    } else {
        /* Assert that there's space for the CRC and length at the end of the buffer */
        OBASSERT(compressionState.avail_in == 8);
    }
    
    free(outputBuffer);
    
    if (withTrailer && compressing) {
        OBASSERT(dataCRC <= UINT32_MAX);
        writeLE32((uint32_t)dataCRC, fp);
        
        OBASSERT(sourceRange.length < UINT32_MAX);
        uint32_t truncatedSourceLength = (uint32_t)(0xFFFFFFFFUL & sourceRange.length);
        writeLE32(truncatedSourceLength, fp);
    }
    if (withTrailer && !compressing) {
        u_int32_t storedCRC, storedLength;
        const u_int8_t *trailerStart;
        
        trailerStart = CFDataGetBytePtr(data) + sourceRange.location + sourceRange.length - 8;
        storedCRC = unpackLE32(trailerStart);
        storedLength = unpackLE32(trailerStart + 4);
        
        if (dataCRC != storedCRC) {
            OFZlibError(compressing, [NSString stringWithFormat:@"CRC error: stored CRC (%08X) does not match computed CRC (%08X)", storedCRC, dataCRC], 0, NULL, outError);
            return FALSE;
        }
        
        if (storedLength != (0xFFFFFFFFUL & compressionState.total_out)) {
            OFZlibError(compressing, [NSString stringWithFormat:@"Gzip error: stored length (%lu) does not match decompressed length (%lu)", (unsigned long)storedLength, (unsigned long)(0xFFFFFFFFUL & compressionState.total_out)], 0, NULL, outError);
            return FALSE;
        }
    }
    
    
    return TRUE;
}

CFDataRef OFDataCreateCompressedGzipData(CFDataRef data, Boolean includeHeader, int level, CFErrorRef *outError)
{
    CFMutableDataRef result;
    
    if (includeHeader)
        result = makeRFC1952MemberHeader((time_t)0, nil, nil, FALSE, FALSE, 0);
    else
        result = CFDataCreateMutable(NULL, 0);

    FILE *writeStream = OFDataCreateReadWriteStandardIOFile(result, outError);
    if (!writeStream) {
        CFRelease(result);
        return NULL;
    }

    fseek(writeStream, 0, SEEK_END);
    Boolean ok = handleRFC1952MemberBody(writeStream, data, (NSRange){0, CFDataGetLength(data)}, level, includeHeader, TRUE, outError);
    fclose(writeStream);
    
    if (!ok) {
        CFRelease(result);
        return NULL;
    }

    return result;
}

CFDataRef OFDataCreateDecompressedGzip2Data(CFAllocatorRef decompressedDataAllocator, CFDataRef data, CFErrorRef *outError)
{
    FILE *readMe = OFDataCreateReadOnlyStandardIOFile(data, outError);
    if (!readMe)
        return NULL;

    Boolean ok = checkRFC1952MemberHeader(readMe, NULL, NULL, NULL);
    size_t headerLength = ftell(readMe);
    fclose(readMe);
    if (!ok) {
        OFZlibError(FALSE/*compressing*/, NSLocalizedStringFromTableInBundle(@"Unable to decompress gzip data: invalid header", @"OmniFoundation", OMNI_BUNDLE, @"decompression exception format"), 0, NULL, outError);
        return NULL;
    }
    
    // While it is conceivable that some crazy person would put valid pointers into a data, compress it and then decompress it later, expecting those pointers to be valid, we don't want to acknowledge such insanity.  So, when garbage collection is on, we ensure that the bytes of the data are in a non-scanned zone.
    
    FILE *writeMe = NULL;
    OFReadWriteFileBuffer *writeBuffer = OFCreateReadWriteFileBuffer(&writeMe, outError);
    if (!writeBuffer)
        return NULL;
    
    ok = handleRFC1952MemberBody(writeMe, data,
                                 (NSRange){ headerLength, CFDataGetLength(data) - headerLength },
                                 Z_DEFAULT_COMPRESSION, TRUE, FALSE, outError);
    
    if (!ok) {
        OFDestroyReadWriteFileBuffer(writeBuffer, decompressedDataAllocator, NULL); // closes the file and frees the buffer w/o returning a data
        return NULL;
    } else {
        CFDataRef result = NULL;
        OFDestroyReadWriteFileBuffer(writeBuffer, decompressedDataAllocator, &result);
        return result;
    }
}
