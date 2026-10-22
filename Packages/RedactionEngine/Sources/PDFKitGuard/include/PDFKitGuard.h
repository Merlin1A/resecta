#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>

NS_ASSUME_NONNULL_BEGIN

/// `-[PDFDocument dataRepresentation]` behind an Objective-C exception
/// boundary.
///
/// PDFKit re-reads the document's attributes while it writes the bytes out
/// and raises `NSInvalidArgumentException` when the file's `/Info`
/// dictionary carries a key it cannot turn into a string (an empty or
/// unreadable name — a damaged or crafted file). Swift cannot intercept an
/// Objective-C exception, so without this boundary the process aborts.
/// Returns the bytes, or nil when PDFKit raised; the caller treats nil as
/// "could not read" on the path it already has for a nil representation.
FOUNDATION_EXPORT NSData * _Nullable RSGuardedDataRepresentation(PDFDocument *document);

NS_ASSUME_NONNULL_END
