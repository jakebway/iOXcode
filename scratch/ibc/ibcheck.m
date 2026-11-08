// ibcheck - load a compiled nib / storyboardc in the simulator and print a normalized object tree.
// usage: ibcheck xib path.nib | ibcheck sb path.storyboardc
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface Owner : NSObject @end
@implementation Owner
- (void)setValue:(id)v forUndefinedKey:(NSString *)k { printf("[owner outlet %s = %s]\n", k.UTF8String, NSStringFromClass([v class]).UTF8String); }
- (id)valueForUndefinedKey:(NSString *)k { return nil; }
@end

static NSString *col(UIColor *c) { if (!c) return @"nil"; CGFloat r, g, b, a; if ([c getRed:&r green:&g blue:&b alpha:&a]) return [NSString stringWithFormat:@"%.3f,%.3f,%.3f,%.2f", r, g, b, a]; return @"?"; }
static NSString *fontS(UIFont *f) { return f ? [NSString stringWithFormat:@"%@ %.1f", f.fontName, f.pointSize] : @"nil"; }

static void dumpView(UIView *v, int ind, NSMutableString *out);
static void line(NSMutableString *out, int ind, NSString *s) { for (int i = 0; i < ind; i++) [out appendString:@"  "]; [out appendFormat:@"%@\n", s]; }

static void dumpView(UIView *v, int ind, NSMutableString *out) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@ frame=%@ mask=%lu tamic=%d hidden=%d alpha=%.2f clips=%d opaque=%d mt=%d ui=%d tag=%ld cm=%ld bg=%@ tint=%@",
        NSStringFromClass([v class]), NSStringFromCGRect(v.frame), (unsigned long)v.autoresizingMask, v.translatesAutoresizingMaskIntoConstraints, v.hidden, v.alpha, v.clipsToBounds, v.opaque, v.multipleTouchEnabled, v.userInteractionEnabled, (long)v.tag, (long)v.contentMode, col(v.backgroundColor), col(v.tintColor)];
    if ([v isKindOfClass:[UILabel class]]) { UILabel *l = (UILabel *)v; [s appendFormat:@" text='%@' font=%@ color=%@ align=%ld lines=%ld lb=%ld adj=%d", l.text, fontS(l.font), col(l.textColor), (long)l.textAlignment, (long)l.numberOfLines, (long)l.lineBreakMode, l.adjustsFontSizeToFitWidth]; }
    if ([v isKindOfClass:[UIButton class]]) { UIButton *b = (UIButton *)v; [s appendFormat:@" title='%@' tcolor=%@ type=%ld", [b titleForState:UIControlStateNormal], col([b titleColorForState:UIControlStateNormal]), (long)b.buttonType]; }
    if ([v isKindOfClass:[UITableViewCell class]]) { UITableViewCell *c = (UITableViewCell *)v; [s appendFormat:@" reuse=%@ acc=%ld sel=%ld", c.reuseIdentifier, (long)c.accessoryType, (long)c.selectionStyle]; }
    line(out, ind, s);
    NSMutableArray *cons = [NSMutableArray new];
    for (NSLayoutConstraint *c in v.constraints) {
        if ([NSStringFromClass([c class]) hasPrefix:@"NSContent"] || [NSStringFromClass([c class]) hasPrefix:@"NSAutoresizing"]) continue;
        [cons addObject:[NSString stringWithFormat:@"%@.%ld %ld %@.%ld x%.2f +%.2f p%.0f", NSStringFromClass([c.firstItem class]), (long)c.firstAttribute, (long)c.relation, c.secondItem ? NSStringFromClass([c.secondItem class]) : @"-", (long)c.secondAttribute, c.multiplier, c.constant, c.priority]];
    }
    [cons sortUsingSelector:@selector(compare:)];
    for (NSString *c in cons) line(out, ind + 1, [@"C " stringByAppendingString:c]);
    for (UIView *sv in v.subviews) dumpView(sv, ind + 1, out);
}

static void dumpVC(UIViewController *vc, int ind, NSMutableString *out) {
    line(out, ind, [NSString stringWithFormat:@"VC %@ title='%@' id=%@ nib=%@", NSStringFromClass([vc class]), vc.title, [vc valueForKey:@"storyboardIdentifier"], vc.nibName]);
    if (vc.navigationItem.title.length || vc.navigationItem.rightBarButtonItems.count) line(out, ind + 1, [NSString stringWithFormat:@"navItem title='%@' right=%lu left=%lu", vc.navigationItem.title, (unsigned long)vc.navigationItem.rightBarButtonItems.count, (unsigned long)vc.navigationItem.leftBarButtonItems.count]);
    if ([vc isKindOfClass:[UISplitViewController class]]) {
        UISplitViewController *sp = (UISplitViewController *)vc;
        line(out, ind + 1, [NSString stringWithFormat:@"split style=%ld display=%ld behavior=%ld primaryBG=%ld", (long)sp.style, (long)sp.preferredDisplayMode, (long)sp.preferredSplitBehavior, (long)sp.primaryBackgroundStyle]);
    }
    @try { [vc loadViewIfNeeded]; } @catch (NSException *e) { line(out, ind + 1, [@"view load failed: " stringByAppendingString:e.reason]); }
    if (vc.isViewLoaded && ![vc isKindOfClass:[UINavigationController class]] && ![vc isKindOfClass:[UISplitViewController class]] && ![vc isKindOfClass:[UITabBarController class]]) dumpView(vc.view, ind + 1, out);
    for (UIViewController *c in vc.childViewControllers) dumpVC(c, ind + 1, out);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSMutableString *out = [NSMutableString new];
        NSString *mode = @(argv[1]), *path = @(argv[2]);
        if ([mode isEqualToString:@"xib"]) {
            NSString *dir = [path stringByDeletingLastPathComponent];
            NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
            NSBundle *b = [NSBundle bundleWithPath:dir];
            UINib *nib = [UINib nibWithNibName:name bundle:b];
            NSArray *objs;
            @try { objs = [nib instantiateWithOwner:[Owner new] options:nil]; } @catch (NSException *e) { printf("INSTANTIATE FAILED: %s\n", e.reason.UTF8String); return 3; }
            for (id o in objs) {
                if ([o isKindOfClass:[UIView class]]) dumpView(o, 0, out);
                else line(out, 0, [NSString stringWithFormat:@"OBJ %@", NSStringFromClass([o class])]);
            }
        } else {
            NSString *dir = [path stringByDeletingLastPathComponent];
            NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
            UIStoryboard *sb = [UIStoryboard storyboardWithName:name bundle:[NSBundle bundleWithPath:dir]];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
            NSArray *ids = [[info[@"UIViewControllerIdentifiersToNibNames"] allKeys] sortedArrayUsingSelector:@selector(compare:)];
            line(out, 0, [NSString stringWithFormat:@"entry=%@", info[@"UIStoryboardDesignatedEntryPointIdentifier"]]);
            for (NSString *i in ids) {
                @try { UIViewController *vc = [sb instantiateViewControllerWithIdentifier:i]; line(out, 0, [@"== " stringByAppendingString:i]); dumpVC(vc, 1, out); }
                @catch (NSException *e) { line(out, 0, [NSString stringWithFormat:@"== %@ FAILED: %@", i, e.reason]); }
            }
        }
        fputs(out.UTF8String, stdout);
    }
    return 0;
}
