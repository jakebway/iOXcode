#import <Foundation/Foundation.h>
#import <dlfcn.h>

@interface CUICatalog : NSObject
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (NSArray *)allImageNames;
- (NSArray *)imagesWithName:(NSString *)name;
- (id)imageWithName:(NSString *)name scaleFactor:(double)scale;
- (id)imageWithName:(NSString *)name scaleFactor:(double)scale deviceIdiom:(long long)idiom;
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW);
        Class cls = NSClassFromString(@"CUICatalog");
        if (!cls) { printf("no CUICatalog\n"); return 1; }
        NSError *err = nil;
        CUICatalog *cat = [[cls alloc] initWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] error:&err];
        if (!cat) { printf("open failed: %s\n", err.description.UTF8String); return 1; }
        NSArray *names = [cat allImageNames];
        printf("names: %lu\n", (unsigned long)names.count);
        int byName = 0, s1 = 0, s2 = 0, s3 = 0, p1 = 0, p2 = 0, p3 = 0;
        NSMutableArray *bad = [NSMutableArray array];
        for (NSString *n in names) {
            NSArray *a = [cat imagesWithName:n];
            if (a.count) byName++; else [bad addObject:n];
            if ([cat imageWithName:n scaleFactor:1.0]) s1++;
            if ([cat imageWithName:n scaleFactor:2.0]) s2++;
            if ([cat imageWithName:n scaleFactor:3.0]) s3++;
            if ([cat imageWithName:n scaleFactor:1.0 deviceIdiom:1]) p1++;
            if ([cat imageWithName:n scaleFactor:2.0 deviceIdiom:1]) p2++;
            if ([cat imageWithName:n scaleFactor:3.0 deviceIdiom:1]) p3++;
        }
        printf("imagesWithName non-empty: %d\n", byName);
        printf("imageWithName scale 1/2/3: %d %d %d\n", s1, s2, s3);
        printf("imageWithName idiom=phone scale 1/2/3: %d %d %d\n", p1, p2, p3);
        printf("empty by name (first 40): %s\n", [[bad subarrayWithRange:NSMakeRange(0, MIN(40, bad.count))] componentsJoinedByString:@", "].UTF8String);
        // first few names that fail at 3x/phone
        NSMutableArray *f3 = [NSMutableArray array];
        for (NSString *n in names) if (![cat imageWithName:n scaleFactor:3.0 deviceIdiom:1]) [f3 addObject:n];
        printf("fail at phone 3x: %lu e.g. %s\n", (unsigned long)f3.count, [[f3 subarrayWithRange:NSMakeRange(0, MIN(30, f3.count))] componentsJoinedByString:@", "].UTF8String);
    }
    return 0;
}
