// ibc - Interface Builder compiler prototype (xib/storyboard XML -> compiled nibs).
// Builds real UIKit objects from the XML and lets UIKit's own UINibEncoder archive them, the way ibtool does.
// Usage: ibc [-v] input.{xib,storyboard} output.{nib,storyboardc}
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static BOOL VERBOSE = NO;
#define LOG(...) do { if (VERBOSE) fprintf(stderr, __VA_ARGS__), fprintf(stderr, "\n"); } while (0)
#define WARN(...) do { fprintf(stderr, "warning: "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } while (0)

#pragma mark - XML tree

@interface N : NSObject
@property (strong) NSString *name;
@property (strong) NSMutableDictionary<NSString *, NSString *> *a;
@property (strong) NSMutableArray<N *> *k;
@property (weak) N *p;
@property (strong) NSMutableString *text;
@end
@implementation N
- (instancetype)init { if ((self = [super init])) { _a = [NSMutableDictionary new]; _k = [NSMutableArray new]; } return self; }
- (N *)first:(NSString *)n { for (N *c in _k) if ([c.name isEqualToString:n]) return c; return nil; }
- (N *)withKey:(NSString *)key { for (N *c in _k) if ([c.a[@"key"] isEqualToString:key]) return c; return nil; }
- (NSArray *)all:(NSString *)n { NSMutableArray *r = [NSMutableArray new]; for (N *c in _k) if ([c.name isEqualToString:n]) [r addObject:c]; return r; }
@end

@interface Parser : NSObject <NSXMLParserDelegate>
@property (strong) N *root; @property (strong) N *cur;
@end
@implementation Parser
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)e namespaceURI:(NSString *)u qualifiedName:(NSString *)q attributes:(NSDictionary *)at {
    N *n = [N new]; n.name = e; [n.a addEntriesFromDictionary:at]; n.p = _cur;
    if (_cur) [_cur.k addObject:n]; else _root = n;
    _cur = n;
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)e namespaceURI:(NSString *)u qualifiedName:(NSString *)q { _cur = _cur.p; }
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s { if (!_cur) return; if (!_cur.text) _cur.text = [NSMutableString new]; [_cur.text appendString:s]; }
@end

#pragma mark - Spoofed archive objects (IB-only encodings)

@interface Spoof : NSObject
@property (strong) NSString *cls;
@property (strong) NSMutableArray *items; // @[key, type, value]
+ (instancetype)cls:(NSString *)c;
- (instancetype)obj:(id)o key:(NSString *)k;
- (instancetype)i32:(int)v key:(NSString *)k;
- (instancetype)b:(BOOL)v key:(NSString *)k;
- (instancetype)dbl:(double)v key:(NSString *)k;
@end
@implementation Spoof
+ (instancetype)cls:(NSString *)c { Spoof *s = [Spoof new]; s.cls = c; s.items = [NSMutableArray new]; return s; }
- (instancetype)obj:(id)o key:(NSString *)k { [_items addObject:@[k, @"o", o ?: [NSNull null]]]; return self; }
- (instancetype)i32:(int)v key:(NSString *)k { [_items addObject:@[k, @"i", @(v)]]; return self; }
- (instancetype)b:(BOOL)v key:(NSString *)k { [_items addObject:@[k, @"b", @(v)]]; return self; }
- (instancetype)dbl:(double)v key:(NSString *)k { [_items addObject:@[k, @"d", @(v)]]; return self; }
- (void)encodeWithCoder:(NSCoder *)c {
    for (NSArray *it in _items) {
        NSString *k = it[0], *t = it[1]; id v = it[2];
        if ([t isEqualToString:@"o"]) { if (v != [NSNull null]) [c encodeObject:v forKey:k]; }
        else if ([t isEqualToString:@"i"]) [c encodeInt32:[v intValue] forKey:k];
        else if ([t isEqualToString:@"b"]) [c encodeBool:[v boolValue] forKey:k];
        else if ([t isEqualToString:@"d"]) [c encodeDouble:[v doubleValue] forKey:k];
    }
}
@end

#pragma mark - Encoder subclass

static NSMapTable *gSwap;      // object -> custom class name (needs UIClassSwapper)
static NSMapTable *gSwapper;   // object -> swapper
static NSMapTable *gFontSpoof; // UIFont -> Spoof
static NSMapTable *gProxy;     // object -> UIProxyObject
static NSMapTable *gAlias;     // object -> replacement object (any)

static id swapperFor(id obj) {
    id s = [gSwapper objectForKey:obj];
    if (s) return s;
    NSString *cn = [gSwap objectForKey:obj];
    if (!cn) return nil;
    s = ((id (*)(Class, SEL, id, id))objc_msgSend)(NSClassFromString(@"UIClassSwapper"), sel_registerName("swapperForObject:withClassName:"), obj, cn);
    [gSwapper setObject:s forKey:obj];
    return s;
}
static id resolve(id o, NSString *key) {
    if (!o) return o;
    id r = [gAlias objectForKey:o]; if (r) o = r;
    r = [gProxy objectForKey:o]; if (r) return r;
    r = [gFontSpoof objectForKey:o]; if (r) return r;
    r = swapperFor(o); if (r) return r;
    return o;
}
static Class makeEncoderClass(void) {
    Class base = NSClassFromString(@"UINibEncoder");
    Class sub = objc_allocateClassPair(base, "IBEncoder", 0);
    SEL rs = sel_registerName("replacementObjectForObject:forKey:");
    IMP orig = class_getMethodImplementation(base, rs);
    class_addMethod(sub, rs, imp_implementationWithBlock(^id(id self, id obj, id key) {
        return ((id (*)(id, SEL, id, id))orig)(self, rs, resolve(obj, key), key);
    }), "@@:@@");
    SEL cn = sel_registerName("encodedClassNameForObject:");
    IMP origCN = class_getMethodImplementation(base, cn);
    class_addMethod(sub, cn, imp_implementationWithBlock(^id(id self, id obj) {
        if ([obj isKindOfClass:[Spoof class]]) return [(Spoof *)obj cls];
        return ((id (*)(id, SEL, id))origCN)(self, cn, obj);
    }), "@@:@");
    objc_registerClassPair(sub);
    return sub;
}

#pragma mark - Enums

static NSDictionary *enumFor(NSString *attr) {
    static NSDictionary *T;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *halign = @{@"center":@0, @"left":@1, @"right":@2, @"fill":@3, @"leading":@4, @"trailing":@5};
        T = @{
            @"contentMode": @{@"scaleToFill":@0, @"scaleAspectFit":@1, @"scaleAspectFill":@2, @"redraw":@3, @"center":@4, @"top":@5, @"bottom":@6, @"left":@7, @"right":@8, @"topLeft":@9, @"topRight":@10, @"bottomLeft":@11, @"bottomRight":@12},
            @"textAlignment": @{@"left":@0, @"center":@1, @"right":@2, @"justified":@3, @"natural":@4},
            @"lineBreakMode": @{@"wordWrap":@0, @"characterWrap":@1, @"clip":@2, @"headTruncation":@3, @"tailTruncation":@4, @"middleTruncation":@5},
            @"baselineAdjustment": @{@"alignBaselines":@0, @"alignCenters":@1, @"none":@2},
            @"contentHorizontalAlignment": halign,
            @"contentVerticalAlignment": @{@"center":@0, @"top":@1, @"bottom":@2, @"fill":@3},
            @"selectionStyle": @{@"none":@0, @"blue":@1, @"gray":@2, @"default":@3},
            @"accessoryType": @{@"none":@0, @"disclosureIndicator":@1, @"detailDisclosureButton":@2, @"checkmark":@3, @"detailButton":@4},
            @"editingAccessoryType": @{@"none":@0, @"disclosureIndicator":@1, @"detailDisclosureButton":@2, @"checkmark":@3, @"detailButton":@4},
            @"separatorStyle": @{@"none":@0, @"singleLine":@1, @"singleLineEtched":@2},
            @"autocapitalizationType": @{@"none":@0, @"words":@1, @"sentences":@2, @"allCharacters":@3},
            @"autocorrectionType": @{@"default":@0, @"no":@1, @"yes":@2},
            @"spellCheckingType": @{@"default":@0, @"no":@1, @"yes":@2},
            @"keyboardType": @{@"default":@0, @"asciiCapable":@1, @"numbersAndPunctuation":@2, @"URL":@3, @"numberPad":@4, @"phonePad":@5, @"namePhonePad":@6, @"emailAddress":@7, @"decimalPad":@8, @"twitter":@9, @"webSearch":@10},
            @"returnKeyType": @{@"default":@0, @"go":@1, @"google":@2, @"join":@3, @"next":@4, @"route":@5, @"search":@6, @"send":@7, @"yahoo":@8, @"done":@9, @"emergencyCall":@10},
            @"borderStyle": @{@"none":@0, @"line":@1, @"bezel":@2, @"roundedRect":@3},
            @"clearButtonMode": @{@"never":@0, @"whileEditing":@1, @"unlessEditing":@2, @"always":@3},
            @"axis": @{@"horizontal":@0, @"vertical":@1},
            @"alignment": @{@"fill":@0, @"leading":@1, @"top":@1, @"firstBaseline":@2, @"center":@3, @"trailing":@4, @"bottom":@4, @"lastBaseline":@5},
            @"distribution": @{@"fill":@0, @"fillEqually":@1, @"fillProportionally":@2, @"equalSpacing":@3, @"equalCentering":@4},
            @"indicatorStyle": @{@"default":@0, @"black":@1, @"white":@2},
            @"keyboardDismissMode": @{@"none":@0, @"onDrag":@1, @"interactive":@2},
            @"style": @{@"plain":@0, @"grouped":@1, @"insetGrouped":@2, @"bordered":@1, @"done":@2},
            @"largeTitleDisplayMode": @{@"automatic":@0, @"always":@1, @"never":@2},
            @"preferredDisplayMode": @{@"automatic":@0, @"secondaryOnly":@1, @"oneBesideSecondary":@2, @"beside":@2, @"oneOverSecondary":@3, @"twoBesideSecondary":@4, @"twoOverSecondary":@5, @"twoDisplaceSecondary":@6},
            @"behavior": @{@"automatic":@0, @"tile":@1, @"overlay":@2, @"displace":@3},
            @"primaryBackgroundStyle": @{@"none":@0, @"sidebar":@1},
            @"modalPresentationStyle": @{@"fullScreen":@0, @"pageSheet":@1, @"formSheet":@2, @"currentContext":@3, @"custom":@4, @"overFullScreen":@5, @"overCurrentContext":@6, @"popover":@7, @"none":@-1, @"automatic":@-2},
            @"modalTransitionStyle": @{@"coverVertical":@0, @"flipHorizontal":@1, @"crossDissolve":@2, @"partialCurl":@3},
            @"sectionInsetReference": @{@"fromContentInset":@0, @"fromSafeArea":@1, @"fromLayoutMargins":@2},
            @"scrollDirection": @{@"vertical":@0, @"horizontal":@1},
            @"activityIndicatorViewStyle": @{@"large":@0, @"medium":@100, @"whiteLarge":@0, @"white":@1, @"gray":@2},
            @"datePickerMode": @{@"time":@0, @"date":@1, @"dateAndTime":@2, @"countDownTimer":@3},
            @"effectStyle": @{},
        };
    });
    return T[attr];
}
static NSInteger enumValue(NSString *attr, NSString *v) {
    NSDictionary *e = enumFor(attr);
    if (e && e[v]) return [e[v] integerValue];
    return [v integerValue];
}

#pragma mark - Builder

@interface Ctx : NSObject
@property (strong) NSMutableDictionary<NSString *, id> *ids;     // XML id -> object
@property (strong) NSMutableDictionary<NSString *, N *> *nodes;  // XML id -> node
@property (strong) NSMutableArray *objectsOrder;                 // objects with ids (pre-order)
@property (strong) NSMutableArray *connections;
@property (strong) NSMutableDictionary *namedColors;             // name -> UIColor
@property (strong) NSMutableDictionary *systemColorDocs;
@property (strong) NSMutableArray *constraintJobs;
@property (strong) NSMutableDictionary *proxies;                 // placeholder id -> proxy
@property (strong) NSString *moduleName;
@end
@implementation Ctx
- (instancetype)init { if ((self = [super init])) { _ids = [NSMutableDictionary new]; _nodes = [NSMutableDictionary new]; _objectsOrder = [NSMutableArray new]; _connections = [NSMutableArray new]; _namedColors = [NSMutableDictionary new]; _constraintJobs = [NSMutableArray new]; _proxies = [NSMutableDictionary new]; } return self; }
@end

static id msg0(id o, const char *sel) { return ((id (*)(id, SEL))objc_msgSend)(o, sel_registerName(sel)); }

static BOOL yes(NSString *s) { return [s isEqualToString:@"YES"]; }

// ---- generic setter by property name using the setter's argument type
static BOOL setGeneric(id obj, NSString *prop, NSString *val) {
    if (!prop.length) return NO;
    NSString *setName = [NSString stringWithFormat:@"set%@%@:", [[prop substringToIndex:1] uppercaseString], [prop substringFromIndex:1]];
    SEL sel = NSSelectorFromString(setName);
    if (![obj respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (sig.numberOfArguments != 3) return NO;
    const char *t = [sig getArgumentTypeAtIndex:2];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = obj; inv.selector = sel;
    switch (t[0]) {
        case 'B': { BOOL b = yes(val); [inv setArgument:&b atIndex:2]; break; }
        case 'c': { char b = yes(val); [inv setArgument:&b atIndex:2]; break; }
        case 'q': case 'l': { long long v = enumValue(prop, val); [inv setArgument:&v atIndex:2]; break; }
        case 'Q': case 'L': { unsigned long long v = (unsigned long long)enumValue(prop, val); [inv setArgument:&v atIndex:2]; break; }
        case 'i': case 's': { int v = (int)enumValue(prop, val); [inv setArgument:&v atIndex:2]; break; }
        case 'I': case 'S': { unsigned v = (unsigned)enumValue(prop, val); [inv setArgument:&v atIndex:2]; break; }
        case 'd': { double v = [val doubleValue]; [inv setArgument:&v atIndex:2]; break; }
        case 'f': { float v = [val floatValue]; [inv setArgument:&v atIndex:2]; break; }
        case '@': { NSString *s = val; [inv setArgument:&s atIndex:2]; break; }
        default: return NO;
    }
    [inv invoke];
    return YES;
}

static NSSet *skipAttrs(void) {
    static NSSet *s;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        s = [NSSet setWithArray:@[@"id", @"customClass", @"customModule", @"customModuleProvider", @"userLabel", @"key", @"sceneMemberID",
            @"storyboardIdentifier", @"ambiguous", @"verifyAmbiguity", @"translatesAutoresizingMaskIntoConstraints", @"colorMatched", @"dataMode",
            @"reuseIdentifier", @"style", @"textLabel", @"detailTextLabel", @"tableViewCell", @"buttonType", @"placeholderIdentifier", @"misplaced",
            @"horizontalHuggingPriority", @"verticalHuggingPriority", @"horizontalCompressionResistancePriority", @"verticalCompressionResistancePriority",
            @"title", @"useStoryboardIdentifierAsRestorationIdentifier", @"wantsLayer", @"wantsLayerBackedHint", @"preferredMaxLayoutWidth", @"image",
            @"catalog", @"systemItem", @"selector", @"destination", @"eventType", @"prefetchingEnabled", @"opaque_"]];
    });
    return s;
}

static NSDictionary *propRename(void) {
    return @{@"clipsSubviews": @"clipsToBounds", @"adjustsFontSizeToFit": @"adjustsFontSizeToFitWidth", @"text_": @"text",
             @"hidden": @"hidden", @"on": @"on", @"prefetchingEnabled": @"prefetchingEnabled"};
}

#pragma mark - Colors / fonts

static UIColor *makeColor(N *n, Ctx *cx, Spoof **spoofOut) {
    NSString *sys = n.a[@"systemColor"];
    if (sys.length) {
        SEL s = NSSelectorFromString(sys);
        if ([UIColor respondsToSelector:s]) return ((id (*)(Class, SEL))objc_msgSend)([UIColor class], s);
        WARN("unknown system color %s", sys.UTF8String);
    }
    NSString *nm = n.a[@"name"];
    if (nm.length && n.a[@"catalog"]) {
        UIColor *c = cx.namedColors[nm];
        if (c) return c;
        WARN("named color %s not found in document resources", nm.UTF8String);
        return [UIColor magentaColor];
    }
    if (n.a[@"white"]) return [UIColor colorWithWhite:[n.a[@"white"] doubleValue] alpha:n.a[@"alpha"] ? [n.a[@"alpha"] doubleValue] : 1];
    if (n.a[@"red"]) return [UIColor colorWithRed:[n.a[@"red"] doubleValue] green:[n.a[@"green"] doubleValue] blue:[n.a[@"blue"] doubleValue] alpha:n.a[@"alpha"] ? [n.a[@"alpha"] doubleValue] : 1];
    return nil;
}

static UIFont *makeFont(N *n) {
    NSString *style = n.a[@"style"];
    if (style.length) {
        UIFont *f = [UIFont preferredFontForTextStyle:style];
        // IB archives a text-style font as a font with UIIBTextStyle set; spoof it so decoding rebuilds a dynamic font.
        return f;
    }
    NSString *type = n.a[@"type"], *name = n.a[@"name"]; CGFloat size = [n.a[@"pointSize"] doubleValue];
    if ([type isEqualToString:@"system"]) return [UIFont systemFontOfSize:size];
    if ([type isEqualToString:@"boldSystem"]) return [UIFont boldSystemFontOfSize:size];
    if ([type isEqualToString:@"italicSystem"]) return [UIFont italicSystemFontOfSize:size];
    if (name.length) { UIFont *f = [UIFont fontWithName:name size:size]; if (f) return f; WARN("font %s not found", name.UTF8String); }
    return [UIFont systemFontOfSize:size ?: 17];
}

#pragma mark - Element table

static Class classForElement(NSString *e) {
    static NSDictionary *T;
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        T = @{
            @"view": @"UIView", @"label": @"UILabel", @"button": @"UIButton", @"imageView": @"UIImageView", @"tableView": @"UITableView",
            @"tableViewCell": @"UITableViewCell", @"collectionView": @"UICollectionView", @"collectionViewCell": @"UICollectionViewCell",
            @"collectionReusableView": @"UICollectionReusableView", @"scrollView": @"UIScrollView", @"stackView": @"UIStackView",
            @"textField": @"UITextField", @"textView": @"UITextView", @"switch": @"UISwitch", @"activityIndicatorView": @"UIActivityIndicatorView",
            @"visualEffectView": @"UIVisualEffectView", @"toolbar": @"UIToolbar", @"navigationBar": @"UINavigationBar", @"tabBar": @"UITabBar",
            @"searchBar": @"UISearchBar", @"slider": @"UISlider", @"progressView": @"UIProgressView", @"segmentedControl": @"UISegmentedControl",
            @"pageControl": @"UIPageControl", @"stepper": @"UIStepper", @"datePicker": @"UIDatePicker", @"pickerView": @"UIPickerView",
            @"wkWebView": @"WKWebView", @"mapView": @"MKMapView", @"tableViewCellContentView": @"UITableViewCellContentView",
            @"viewController": @"UIViewController", @"tableViewController": @"UITableViewController", @"collectionViewController": @"UICollectionViewController",
            @"navigationController": @"UINavigationController", @"tabBarController": @"UITabBarController", @"splitViewController": @"UISplitViewController",
            @"pageViewController": @"UIPageViewController", @"customObject": @"NSObject",
        };
    });
    NSString *c = T[e];
    return c ? NSClassFromString(c) : nil;
}

static BOOL isViewControllerElement(NSString *e) {
    return [e hasSuffix:@"Controller"] && ![e isEqualToString:@"customObject"];
}

static NSString *mangled(NSString *module, NSString *cls) {
    if (!module.length || [cls containsString:@"."]) return cls;
    return [NSString stringWithFormat:@"_TtC%lu%@%lu%@", (unsigned long)module.length, module, (unsigned long)cls.length, cls];
}

static id build(N *n, Ctx *cx, id parent);

static void registerObject(Ctx *cx, N *n, id obj) {
    NSString *i = n.a[@"id"];
    if (!i) return;
    cx.ids[i] = obj; cx.nodes[i] = n;
    [cx.objectsOrder addObject:obj];
}

static void applyCustomClass(N *n, id obj) {
    NSString *cc = n.a[@"customClass"];
    if (!cc.length) return;
    NSString *mod = n.a[@"customModule"];
    if (n.a[@"customModuleProvider"] && ![n.a[@"customModuleProvider"] isEqualToString:@"target"]) mod = nil; // module from a package: name is global
    [gSwap setObject:mangled(mod, cc) forKey:obj];
}

static void setPriority(UIView *v, N *n) {
    for (NSArray *p in @[@[@"horizontalHuggingPriority", @0, @0], @[@"verticalHuggingPriority", @1, @0], @[@"horizontalCompressionResistancePriority", @0, @1], @[@"verticalCompressionResistancePriority", @1, @1]]) {
        NSString *v_ = n.a[p[0]]; if (!v_) continue;
        UILayoutConstraintAxis ax = [p[1] integerValue] ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
        if ([p[2] integerValue]) [v setContentCompressionResistancePriority:[v_ floatValue] forAxis:ax];
        else [v setContentHuggingPriority:[v_ floatValue] forAxis:ax];
    }
}

static void applyAttrs(id obj, N *n) {
    NSDictionary *ren = propRename();
    for (NSString *k in n.a) {
        if ([skipAttrs() containsObject:k]) continue;
        NSString *prop = ren[k] ?: k;
        if (!setGeneric(obj, prop, n.a[k])) LOG("  (attr %s on %s unhandled)", k.UTF8String, n.name.UTF8String);
    }
    if ([obj isKindOfClass:[UIView class]]) {
        setPriority(obj, n);
        if (n.a[@"translatesAutoresizingMaskIntoConstraints"]) [obj setTranslatesAutoresizingMaskIntoConstraints:yes(n.a[@"translatesAutoresizingMaskIntoConstraints"])];
        if (n.a[@"userInteractionEnabled"]) [obj setUserInteractionEnabled:yes(n.a[@"userInteractionEnabled"])];
    }
}

static CGRect rectOf(N *r) { return CGRectMake([r.a[@"x"] doubleValue], [r.a[@"y"] doubleValue], [r.a[@"width"] doubleValue], [r.a[@"height"] doubleValue]); }

static UIViewAutoresizing maskOf(N *m) {
    UIViewAutoresizing r = 0;
    if (yes(m.a[@"flexibleMinX"])) r |= UIViewAutoresizingFlexibleLeftMargin;
    if (yes(m.a[@"widthSizable"])) r |= UIViewAutoresizingFlexibleWidth;
    if (yes(m.a[@"flexibleMaxX"])) r |= UIViewAutoresizingFlexibleRightMargin;
    if (yes(m.a[@"flexibleMinY"])) r |= UIViewAutoresizingFlexibleTopMargin;
    if (yes(m.a[@"heightSizable"])) r |= UIViewAutoresizingFlexibleHeight;
    if (yes(m.a[@"flexibleMaxY"])) r |= UIViewAutoresizingFlexibleBottomMargin;
    return r;
}

static UIImage *imageNamedPlaceholder(NSString *name, BOOL system) {
    UIImage *i = system ? [UIImage systemImageNamed:name] : nil;
    return i;
}

static void applyViewChildren(UIView *v, N *n, Ctx *cx);

static UIBarButtonItem *buildBarButtonItem(N *n, Ctx *cx) {
    UIBarButtonItem *b;
    NSString *si = n.a[@"systemItem"];
    if (si.length) {
        static NSDictionary *S;
        static dispatch_once_t o;
        dispatch_once(&o, ^{ S = @{@"done":@0, @"cancel":@1, @"edit":@2, @"save":@3, @"add":@4, @"flexibleSpace":@5, @"fixedSpace":@6, @"compose":@7, @"reply":@8, @"action":@9, @"organize":@10, @"bookmarks":@11, @"search":@12, @"refresh":@13, @"stop":@14, @"camera":@15, @"trash":@16, @"play":@17, @"pause":@18, @"rewind":@19, @"fastForward":@20, @"undo":@21, @"redo":@22, @"close":@24}; });
        b = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:[S[si] integerValue] target:nil action:nil];
    } else {
        b = [UIBarButtonItem new];
        if (n.a[@"title"]) b.title = n.a[@"title"];
        N *img = [n withKey:@"image"];
        if (n.a[@"image"]) {
            BOOL sys = [n.a[@"catalog"] isEqualToString:@"system"];
            UIImage *im = imageNamedPlaceholder(n.a[@"image"], sys);
            if (im) b.image = im;
        }
        (void)img;
        if (n.a[@"style"]) b.style = (UIBarButtonItemStyle)enumValue(@"style", n.a[@"style"]);
    }
    if (n.a[@"enabled"]) b.enabled = yes(n.a[@"enabled"]);
    registerObject(cx, n, b);
    // Actions / outlets inside barButtonItem
    N *c = [n first:@"connections"];
    for (N *a in c.k) {
        if ([a.name isEqualToString:@"action"]) {
            // connection: bar button item -> destination, selector
            [cx.connections addObject:@{@"kind":@"event", @"source":n.a[@"id"] ?: @"", @"dest":a.a[@"destination"] ?: @"", @"sel":a.a[@"selector"] ?: @"", @"event":a.a[@"eventType"] ?: @""}];
        }
    }
    return b;
}

static void applyControlStates(UIButton *b, N *n) {
    for (N *s in [n all:@"state"]) {
        UIControlState st = UIControlStateNormal;
        NSString *k = s.a[@"key"];
        if ([k isEqualToString:@"highlighted"]) st = UIControlStateHighlighted;
        else if ([k isEqualToString:@"selected"]) st = UIControlStateSelected;
        else if ([k isEqualToString:@"disabled"]) st = UIControlStateDisabled;
        if (s.a[@"title"]) [b setTitle:s.a[@"title"] forState:st];
        N *c = [s withKey:@"titleColor"]; if (c) [b setTitleColor:makeColor(c, nil, NULL) forState:st];
    }
}

static void applyViewChildren(UIView *v, N *n, Ctx *cx) {
    for (N *c in n.k) {
        NSString *e = c.name, *key = c.a[@"key"];
        if ([e isEqualToString:@"rect"] && [key isEqualToString:@"frame"]) { v.frame = rectOf(c); }
        else if ([e isEqualToString:@"autoresizingMask"]) { v.autoresizingMask = maskOf(c); }
        else if ([e isEqualToString:@"color"] && key) {
            UIColor *col = makeColor(c, cx, NULL);
            NSString *prop = key;
            if ([key isEqualToString:@"highlightedColor"]) prop = @"highlightedTextColor";
            if ([key isEqualToString:@"separatorColor"]) prop = @"separatorColor";
            if (col && !(([prop isEqualToString:@"textColor"]) && !col)) {
                NSString *setName = [NSString stringWithFormat:@"set%@%@:", [[prop substringToIndex:1] uppercaseString], [prop substringFromIndex:1]];
                if ([v respondsToSelector:NSSelectorFromString(setName)]) ((void (*)(id, SEL, id))objc_msgSend)(v, NSSelectorFromString(setName), col);
                else LOG("  (color %s unhandled)", key.UTF8String);
            }
        }
        else if ([e isEqualToString:@"fontDescription"]) {
            UIFont *f = makeFont(c);
            if ([v respondsToSelector:@selector(setFont:)]) ((void (*)(id, SEL, id))objc_msgSend)(v, @selector(setFont:), f);
        }
        else if ([e isEqualToString:@"tableViewCellContentView"] || [e isEqualToString:@"collectionViewCellContentView"]) { build(c, cx, v); }
        else if ([e isEqualToString:@"subviews"]) {
            for (N *sv in c.k) {
                id sub = build(sv, cx, v);
                if ([sub isKindOfClass:[UIView class]]) {
                    UIView *container = v;
                    if ([v isKindOfClass:[UITableViewCell class]]) container = [(UITableViewCell *)v contentView];
                    if ([sub superview] != container) [container addSubview:sub];
                }
            }
        }
        else if ([e isEqualToString:@"constraints"]) { [cx.constraintJobs addObject:@[v, c]]; }
        else if ([e isEqualToString:@"connections"]) {
            NSString *vid = n.a[@"id"] ?: @"";
            for (N *cc in c.k) {
                if ([cc.name isEqualToString:@"outlet"]) [cx.connections addObject:@{@"kind":@"outlet", @"source":vid, @"dest":cc.a[@"destination"] ?: @"", @"label":cc.a[@"property"] ?: @""}];
                else if ([cc.name isEqualToString:@"action"]) [cx.connections addObject:@{@"kind":@"event", @"source":vid, @"dest":cc.a[@"destination"] ?: @"", @"sel":cc.a[@"selector"] ?: @"", @"event":cc.a[@"eventType"] ?: @"touchUpInside"}];
                else if ([cc.name isEqualToString:@"outletCollection"]) [cx.connections addObject:@{@"kind":@"collection", @"source":vid, @"dest":cc.a[@"destination"] ?: @"", @"label":cc.a[@"property"] ?: @"", @"coll":cc.a[@"collectionClass"] ?: @"NSArray"}];
            }
        }
        else if ([e isEqualToString:@"state"]) { /* handled by applyControlStates */ }
        else if ([e isEqualToString:@"viewLayoutGuide"]) {
            NSString *gid = c.a[@"id"];
            UILayoutGuide *g = nil;
            if ([key isEqualToString:@"safeArea"]) g = v.safeAreaLayoutGuide;
            else if ([key isEqualToString:@"layoutMargins"]) g = v.layoutMarginsGuide;
            else if ([key isEqualToString:@"readableContent"]) g = v.readableContentGuide;
            else if ([key isEqualToString:@"contentLayoutGuide"]) g = [(UIScrollView *)v contentLayoutGuide];
            else if ([key isEqualToString:@"frameLayoutGuide"]) g = [(UIScrollView *)v frameLayoutGuide];
            if (g && gid) { cx.ids[gid] = g; cx.nodes[gid] = c; [cx.objectsOrder addObject:g]; }
        }
        else if ([e isEqualToString:@"userDefinedRuntimeAttributes"]) {
            for (N *ra in c.k) {
                NSString *kp = ra.a[@"keyPath"], *t = ra.a[@"type"];
                if (!kp) continue;
                id val = nil;
                if ([t isEqualToString:@"boolean"]) val = @(yes(ra.a[@"value"]));
                else if ([t isEqualToString:@"number"]) val = @([ra.a[@"value"] doubleValue]);
                else if ([t isEqualToString:@"string"]) val = ra.a[@"value"];
                else { LOG("  (runtime attribute type %s unhandled)", t.UTF8String); continue; }
                @try { [v setValue:val forKeyPath:kp]; } @catch (NSException *ex) { LOG("  (runtime attribute %s failed)", kp.UTF8String); }
            }
        }
    }
}

static NSLayoutAttribute layoutAttr(NSString *s) {
    static NSDictionary *T;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ T = @{@"left":@1, @"right":@2, @"top":@3, @"bottom":@4, @"leading":@5, @"trailing":@6, @"width":@7, @"height":@8, @"centerX":@9, @"centerY":@10, @"baseline":@11, @"lastBaseline":@11, @"firstBaseline":@12,
        @"leftMargin":@13, @"rightMargin":@14, @"topMargin":@15, @"bottomMargin":@16, @"leadingMargin":@17, @"trailingMargin":@18, @"centerXWithinMargins":@19, @"centerYWithinMargins":@20}; });
    return s ? (NSLayoutAttribute)[T[s] integerValue] : NSLayoutAttributeNotAnAttribute;
}

static void buildConstraints(Ctx *cx) {
    for (NSArray *job in cx.constraintJobs) {
        UIView *owner = job[0]; N *cs = job[1];
        for (N *c in cs.k) {
            if (![c.name isEqualToString:@"constraint"]) continue;
            id a = c.a[@"firstItem"] ? cx.ids[c.a[@"firstItem"]] : owner;
            id b = c.a[@"secondItem"] ? cx.ids[c.a[@"secondItem"]] : nil;
            if (!a) { WARN("constraint %s: first item missing", c.a[@"id"].UTF8String); continue; }
            NSLayoutRelation rel = NSLayoutRelationEqual;
            if ([c.a[@"relation"] isEqualToString:@"greaterThanOrEqual"]) rel = NSLayoutRelationGreaterThanOrEqual;
            if ([c.a[@"relation"] isEqualToString:@"lessThanOrEqual"]) rel = NSLayoutRelationLessThanOrEqual;
            NSLayoutConstraint *lc = [NSLayoutConstraint constraintWithItem:a attribute:layoutAttr(c.a[@"firstAttribute"]) relatedBy:rel toItem:b attribute:b ? layoutAttr(c.a[@"secondAttribute"]) : NSLayoutAttributeNotAnAttribute multiplier:c.a[@"multiplier"] ? [c.a[@"multiplier"] doubleValue] : 1 constant:[c.a[@"constant"] doubleValue]];
            if (c.a[@"priority"]) lc.priority = [c.a[@"priority"] floatValue];
            if (c.a[@"identifier"]) lc.identifier = c.a[@"identifier"];
            [owner addConstraint:lc];
            if (c.a[@"id"]) { cx.ids[c.a[@"id"]] = lc; cx.nodes[c.a[@"id"]] = c; }
        }
    }
}

static id build(N *n, Ctx *cx, id parent) {
    NSString *e = n.name;
    Class cls = classForElement(e);
    if (!cls) { WARN("unsupported element <%s>", e.UTF8String); return nil; }
    LOG("build <%s> id=%s", e.UTF8String, n.a[@"id"].UTF8String);
    id obj = nil;
    if ([e isEqualToString:@"tableViewCell"]) {
        NSString *st = n.a[@"style"];
        UITableViewCellStyle style = UITableViewCellStyleDefault;
        if ([st isEqualToString:@"IBUITableViewCellStyleValue1"]) style = UITableViewCellStyleValue1;
        else if ([st isEqualToString:@"IBUITableViewCellStyleValue2"]) style = UITableViewCellStyleValue2;
        else if ([st isEqualToString:@"IBUITableViewCellStyleSubtitle"]) style = UITableViewCellStyleSubtitle;
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:n.a[@"reuseIdentifier"]];
        obj = cell;
        if (n.a[@"textLabel"]) { cx.ids[n.a[@"textLabel"]] = cell.textLabel; cx.nodes[n.a[@"textLabel"]] = [N new]; }
        if (n.a[@"detailTextLabel"]) { cx.ids[n.a[@"detailTextLabel"]] = cell.detailTextLabel; }
    } else if ([e isEqualToString:@"tableViewCellContentView"] || [e isEqualToString:@"collectionViewCellContentView"]) {
        UIView *cv = [(id)parent contentView];
        obj = cv;
    } else if ([e isEqualToString:@"label"]) {
        // textLabel/detailTextLabel of a cell are pre-created
        id pre = n.a[@"id"] ? cx.ids[n.a[@"id"]] : nil;
        obj = pre ?: [UILabel new];
    } else if ([e isEqualToString:@"button"]) {
        NSDictionary *bt = @{@"custom":@0, @"roundedRect":@1, @"detailDisclosure":@2, @"infoLight":@3, @"infoDark":@4, @"contactAdd":@5, @"system":@1};
        obj = [UIButton buttonWithType:(UIButtonType)[bt[n.a[@"buttonType"] ?: @"custom"] integerValue]];
    } else if ([e isEqualToString:@"collectionView"]) {
        N *lay = [n withKey:@"collectionViewLayout"];
        UICollectionViewLayout *l = [UICollectionViewFlowLayout new];
        if (lay) {
            UICollectionViewFlowLayout *fl = (UICollectionViewFlowLayout *)l;
            for (N *c in lay.k) {
                if ([c.name isEqualToString:@"size"]) {
                    CGSize sz = CGSizeMake([c.a[@"width"] doubleValue], [c.a[@"height"] doubleValue]);
                    if ([c.a[@"key"] isEqualToString:@"itemSize"]) fl.itemSize = sz;
                    else if ([c.a[@"key"] isEqualToString:@"headerReferenceSize"]) fl.headerReferenceSize = sz;
                    else if ([c.a[@"key"] isEqualToString:@"footerReferenceSize"]) fl.footerReferenceSize = sz;
                    else if ([c.a[@"key"] isEqualToString:@"estimatedItemSize"]) fl.estimatedItemSize = sz;
                } else if ([c.name isEqualToString:@"inset"] && [c.a[@"key"] isEqualToString:@"sectionInset"]) {
                    fl.sectionInset = UIEdgeInsetsMake([c.a[@"minY"] doubleValue], [c.a[@"minX"] doubleValue], [c.a[@"maxY"] doubleValue], [c.a[@"maxX"] doubleValue]);
                }
            }
            applyAttrs(fl, lay);
            registerObject(cx, lay, fl);
        }
        obj = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:l];
    } else if ([e isEqualToString:@"tableView"]) {
        UITableViewStyle ts = (UITableViewStyle)enumValue(@"style", n.a[@"style"] ?: @"plain");
        obj = [[UITableView alloc] initWithFrame:CGRectZero style:ts];
    } else if ([e isEqualToString:@"collectionViewCell"] || [e isEqualToString:@"collectionReusableView"]) {
        obj = [[cls alloc] initWithFrame:CGRectZero];
    } else if (isViewControllerElement(e)) {
        obj = [[cls alloc] init];
    } else if ([e isEqualToString:@"wkWebView"] || [e isEqualToString:@"mapView"]) {
        obj = cls ? [[cls alloc] initWithFrame:CGRectZero] : [UIView new];
    } else if ([cls isSubclassOfClass:[UIView class]]) {
        obj = [[cls alloc] initWithFrame:CGRectZero];
    } else {
        obj = [[cls alloc] init];
    }
    registerObject(cx, n, obj);
    applyCustomClass(n, obj);
    applyAttrs(obj, n);
    if ([obj isKindOfClass:[UIButton class]]) applyControlStates(obj, n);
    if ([obj isKindOfClass:[UIView class]]) applyViewChildren(obj, n, cx);
    return obj;
}

#pragma mark - Document -> nib

static id proxyFor(Ctx *cx, NSString *ident) {
    id p = cx.proxies[ident];
    if (p) return p;
    p = [[NSClassFromString(@"UIProxyObject") alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(p, sel_registerName("setProxiedObjectIdentifier:"), ident);
    cx.proxies[ident] = p;
    return p;
}

static id makeConnection(NSDictionary *d, Ctx *cx, id (^resolveObj)(NSString *)) {
    NSString *kind = d[@"kind"];
    id src = resolveObj(d[@"source"]), dst = resolveObj(d[@"dest"]);
    if (!src || !dst) { WARN("connection %s unresolved (%s -> %s)", [d[@"label"] ?: d[@"sel"] UTF8String], [d[@"source"] UTF8String], [d[@"dest"] UTF8String]); return nil; }
    Class c = NSClassFromString([kind isEqualToString:@"event"] ? @"UIRuntimeEventConnection" : [kind isEqualToString:@"collection"] ? @"UIRuntimeOutletCollectionConnection" : @"UIRuntimeOutletConnection");
    id conn = [[c alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(conn, sel_registerName("setSource:"), src);
    ((void (*)(id, SEL, id))objc_msgSend)(conn, sel_registerName("setDestination:"), dst);
    ((void (*)(id, SEL, id))objc_msgSend)(conn, sel_registerName("setLabel:"), d[@"label"] ?: d[@"sel"]);
    if ([kind isEqualToString:@"event"] && d[@"event"]) {
        static NSDictionary *ev;
        static dispatch_once_t o;
        dispatch_once(&o, ^{ ev = @{@"touchDown":@1, @"touchDownRepeat":@2, @"touchDragInside":@4, @"touchDragOutside":@8, @"touchDragEnter":@16, @"touchDragExit":@32, @"touchUpInside":@64, @"touchUpOutside":@128, @"touchCancel":@256, @"valueChanged":@4096, @"primaryActionTriggered":@8192, @"editingDidBegin":@65536, @"editingChanged":@131072, @"editingDidEnd":@262144, @"editingDidEndOnExit":@524288}; });
        NSUInteger m = [ev[d[@"event"]] unsignedIntegerValue];
        if (m) ((void (*)(id, SEL, NSUInteger))objc_msgSend)(conn, sel_registerName("setEventMask:"), m);
    }
    return conn;
}

static NSData *encodeNib(NSArray *topLevel, NSArray *allObjects, NSArray *conns) {
    NSMutableData *data = [NSMutableData new];
    Class ec = makeEncoderClass();
    id enc = ((id (*)(id, SEL, id))objc_msgSend)([ec alloc], sel_registerName("initForWritingWithMutableData:"), data);
    [enc encodeObject:topLevel forKey:@"UINibTopLevelObjectsKey"];
    [enc encodeObject:allObjects forKey:@"UINibObjectsKey"];
    [enc encodeObject:conns forKey:@"UINibConnectionsKey"];
    [enc encodeObject:@[] forKey:@"UINibVisibleWindowsKey"];
    [enc encodeObject:@[] forKey:@"UINibAccessibilityConfigurationsKey"];
    [enc encodeObject:@[] forKey:@"UINibTraitStorageListsKey"];
    [enc encodeObject:@[] forKey:@"UINibKeyValuePairsKey"];
    ((void (*)(id, SEL))objc_msgSend)(enc, sel_registerName("finishEncoding"));
    return data;
}

static void collectResources(N *doc, Ctx *cx) {
    N *res = [doc first:@"resources"];
    for (N *r in res.k) {
        if ([r.name isEqualToString:@"namedColor"]) {
            N *c = [r first:@"color"];
            if (c) { UIColor *col = makeColor(c, cx, NULL); if (col) cx.namedColors[r.a[@"name"]] = col; }
        }
    }
}

static BOOL compileXib(N *doc, NSString *outPath) {
    Ctx *cx = [Ctx new];
    collectResources(doc, cx);
    N *objs = [doc first:@"objects"];
    NSMutableArray *top = [NSMutableArray new];
    for (N *c in objs.k) {
        if ([c.name isEqualToString:@"placeholder"]) {
            NSString *pid = c.a[@"placeholderIdentifier"];
            id p = proxyFor(cx, pid);
            cx.ids[c.a[@"id"]] = p; [top addObject:p];
            if (c.a[@"customClass"] && [pid isEqualToString:@"IBFilesOwner"]) { /* owner class is applied at load time */ }
        } else {
            id o = build(c, cx, nil);
            if (o) [top addObject:o];
        }
    }
    buildConstraints(cx);
    NSMutableArray *conns = [NSMutableArray new];
    id (^resolveObj)(NSString *) = ^id(NSString *i) { return cx.ids[i]; };
    // connections declared on placeholders (File's Owner outlets)
    for (N *c in objs.k) {
        if ([c.name isEqualToString:@"placeholder"]) {
            N *cc = [c first:@"connections"];
            for (N *x in cc.k) if ([x.name isEqualToString:@"outlet"]) [cx.connections addObject:@{@"kind":@"outlet", @"source":c.a[@"id"] ?: @"", @"dest":x.a[@"destination"] ?: @"", @"label":x.a[@"property"] ?: @""}];
        }
    }
    for (NSDictionary *d in cx.connections) { id conn = makeConnection(d, cx, resolveObj); if (conn) [conns addObject:conn]; }
    NSMutableArray *all = [NSMutableArray new];
    for (id p in cx.proxies.allValues) [all addObject:p];
    [all addObjectsFromArray:cx.objectsOrder];
    NSData *d = encodeNib(top, all, conns);
    return [d writeToFile:outPath atomically:YES];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int i = 1;
        if (argc > 1 && !strcmp(argv[1], "-v")) { VERBOSE = YES; i++; }
        if (argc - i < 2) { fprintf(stderr, "usage: ibc [-v] in out\n"); return 2; }
        gSwap = [NSMapTable strongToStrongObjectsMapTable];
        gSwapper = [NSMapTable strongToStrongObjectsMapTable];
        gFontSpoof = [NSMapTable strongToStrongObjectsMapTable];
        gProxy = [NSMapTable strongToStrongObjectsMapTable];
        gAlias = [NSMapTable strongToStrongObjectsMapTable];
        NSString *in = @(argv[i]), *out = @(argv[i + 1]);
        NSData *xml = [NSData dataWithContentsOfFile:in];
        NSXMLParser *xp = [[NSXMLParser alloc] initWithData:xml];
        Parser *ps = [Parser new]; xp.delegate = ps; [xp parse];
        if (!ps.root) { fprintf(stderr, "cannot parse %s\n", argv[i]); return 1; }
        BOOL ok = compileXib(ps.root, out);
        return ok ? 0 : 1;
    }
}
