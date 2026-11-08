#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
static void dumpClass(const char *name) {
    Class c = objc_getClass(name);
    if (!c) { printf("== %s: NOT FOUND\n", name); return; }
    printf("== %s (super %s)\n", name, class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "-");
    for (int meta = 0; meta < 2; meta++) {
        Class k = meta ? object_getClass(c) : c;
        unsigned n; Method *ms = class_copyMethodList(k, &n);
        for (unsigned i = 0; i < n; i++) printf("  %c %s  %s\n", meta ? '+' : '-', sel_getName(method_getName(ms[i])), method_getTypeEncoding(ms[i]));
        free(ms);
    }
}
int main(void) {
    @autoreleasepool {
        dumpClass("UINibEncoder");
        dumpClass("UINibDecoder");
        dumpClass("UIClassSwapper");
        dumpClass("UIProxyObject");
        dumpClass("UIRuntimeOutletConnection");
        dumpClass("UIRuntimeEventConnection");
        dumpClass("UIRuntimeOutletCollectionConnection");
        dumpClass("UIStoryboardSegueTemplate");
        dumpClass("UIStoryboard");
    }
    return 0;
}
