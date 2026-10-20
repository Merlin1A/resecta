#import "PDFKitGuard.h"

NSData * _Nullable RSGuardedDataRepresentation(PDFDocument *document) {
    @try {
        return [document dataRepresentation];
    } @catch (NSException *exception) {
        // The exception carries only PDFKit's own message (a nil
        // dictionary key); nothing from the file is kept.
        return nil;
    }
}
