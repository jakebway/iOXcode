#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
static const char *FILTER = NULL;
static void dumpClass(const char *name) {
    Class c = objc_getClass(name);
    if (!c) { printf("== %s: NOT FOUND\n", name); return; }
    printf("== %s (super %s)\n", name, class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "-");
    for (int meta = 0; meta < 2; meta++) {
        Class k = meta ? object_getClass(c) : c;
        unsigned n; Method *ms = class_copyMethodList(k, &n);
        for (unsigned i = 0; i < n; i++) if (!FILTER || strstr(sel_getName(method_getName(ms[i])), FILTER) || strcasestr(sel_getName(method_getName(ms[i])), FILTER)) printf("  %c %s  %s\n", meta ? '+' : '-', sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i]));
        free(ms);
    }
}
int main(int argc, char **argv) {
    @autoreleasepool {
        for (int i = 1; i + 1 < argc; i += 2) { FILTER = strcmp(argv[i+1], "-") ? argv[i+1] : NULL; dumpClass(argv[i]); }
    }
    return 0;
}
