#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <CoreGraphics/CoreGraphics.h>
@interface CUICatalog : NSObject
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (NSArray *)allImageNames;
- (NSArray *)imagesWithName:(NSString *)name;
- (id)imageWithName:(NSString *)name scaleFactor:(double)scale;
- (id)imageWithName:(NSString *)name scaleFactor:(double)scale deviceIdiom:(long long)idiom;
@end

@interface CUINamedImage : NSObject
- (CGImageRef)image;
- (double)scale;
@end
static void alphaStats(CUICatalog *cat, NSString *n) {
    id im = [cat imageWithName:n scaleFactor:2.0 deviceIdiom:1];
    if (!im) { printf("ALPHA %s: nil\n", n.UTF8String); return; }
    CGImageRef cg = [(CUINamedImage*)im image];
    if (!cg) { printf("ALPHA %s: no cgimage\n", n.UTF8String); return; }
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    uint8_t *buf = calloc(w*h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w*4, cs, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0,0,w,h), cg);
    size_t clear=0, part=0, black=0;
    for (size_t i=0;i<w*h;i++){ uint8_t a=buf[i*4+3]; if(a==0) clear++; else if(a<255) part++; if(a==255&&!buf[i*4]&&!buf[i*4+1]&&!buf[i*4+2]) black++; }
    printf("ALPHA %s: %zux%zu alphaInfo=%d clear=%zu partial=%zu opaqueBlack=%zu\n", n.UTF8String, w, h, (int)CGImageGetAlphaInfo(cg), clear, part, black);
    CGContextRelease(ctx); CGColorSpaceRelease(cs); free(buf);
}

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
        for (NSString *n in @[@"App Store",@"SBDockBG 2",@"Calculator",@"Phone",@"Wallpaper_1"]) alphaStats(cat, n);
        printf("fail at phone 3x: %lu e.g. %s\n", (unsigned long)f3.count, [[f3 subarrayWithRange:NSMakeRange(0, MIN(30, f3.count))] componentsJoinedByString:@", "].UTF8String);
    }
    return 0;
}
