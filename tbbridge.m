// tbbridge.m — Objective-C 桥接：调用 AppKit 的私有「系统模态 Touch Bar」接口。
//
//   +[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]
//   +[NSTouchBar dismissSystemModalTouchBar:]
//
// 这两个类方法没有出现在公开头文件里，但运行时存在。
// 在 Swift 里手工构造 IMP 调用的 receiver 容易出错（会导致 EXC_BAD_ACCESS），
// 所以这里用 ObjC 的 objc_msgSend 显式发送消息，最稳妥。
#import <AppKit/AppKit.h>
#import <objc/message.h>

#ifndef TB_MIN
#define TB_MIN(a, b) ((a) < (b) ? (a) : (b))
#endif

static SEL TB_sel_present(void) {
    return sel_registerName("presentSystemModalTouchBar:systemTrayItemIdentifier:");
}
static SEL TB_sel_dismiss(void) {
    return sel_registerName("dismissSystemModalTouchBar:");
}

BOOL TB_systemModalTouchBarAvailable(void) {
    return class_getClassMethod([NSTouchBar class], TB_sel_present()) != NULL
        && class_getClassMethod([NSTouchBar class], TB_sel_dismiss()) != NULL;
}

void TB_presentSystemModalTouchBar(NSTouchBar *tb, NSString *trayItemIdentifier) {
    ((void (*)(id, SEL, NSTouchBar *, NSString *))objc_msgSend)(
        [NSTouchBar class], TB_sel_present(), tb, trayItemIdentifier);
}

void TB_dismissSystemModalTouchBar(NSTouchBar *tb) {
    ((void (*)(id, SEL, NSTouchBar *))objc_msgSend)(
        [NSTouchBar class], TB_sel_dismiss(), tb);
}

// ---------------------------------------------------------------------------
// 亮度工具：NSColor 的 RGB 通道 × factor（保留色相，直接缩放三通道）
//   比 HSB 方案更安全：NSColor(red:...) 内部是 NSColorSpaceColor，
//   它不响应 usingColorSpace:，所以改用 sRGB 转换 + getRed 直接取值再缩放。
//   factor = brightness/100：0 → 全黑，1.0 → 原样
// ---------------------------------------------------------------------------
NSColor *TB_dimColor(NSColor *color, float factor) {
    if (factor >= 0.999f) return color;

    // 先尝试转换到 sRGB，让 getRed: 能正常工作（NSColorSpaceColor 会响应）
    NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!c) return color;

    CGFloat r, g, b, a;
    [c getRed:&r green:&g blue:&b alpha:&a];
    r = r * (CGFloat)factor;  if (r > 1.0) r = 1.0;  if (r < 0.0) r = 0.0;
    g = g * (CGFloat)factor;  if (g > 1.0) g = 1.0;  if (g < 0.0) g = 0.0;
    b = b * (CGFloat)factor;  if (b > 1.0) b = 1.0;  if (b < 0.0) b = 0.0;
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
}

// ---------------------------------------------------------------------------
// 合成「彩色圆角背景 + 白色图标」为一张 48×48 的 NSImage，并整体按 factor 缩放亮度。
//   为什么必须合成：NSButtonTouchBarItem.bezelColor 在 macOS 14+ 的 system-modal
//   渲染管线里被 TouchBarServer 忽略，只改 bezelColor 用户看不到任何明暗变化。
//   所以把背景色直接烘进 item.image 的像素里。
//
//   关键（曾导致 EXC_BAD_ACCESS 的坑）：用 bitmapDataPlanes:NULL 让
//   NSBitmapImageRep 自己分配并持有内部缓冲；绝不用传入外部 buffer 再 free
//   （那样 TouchBarServer 异步渲染时会读到已释放内存 → 崩溃）。
//   绘制完成后直接操作 rep 自身的 bitmapData 做像素缩放，安全无悬垂指针。
// ---------------------------------------------------------------------------
NSImage *TB_buildItemImage(NSString *symbol, NSColor *tint, float factor, NSString *label) {
    const int W = 48, H = 48;
    // 在池外声明结果变量：@autoreleasepool 内的临时对象（ctx / symbol 图等）
    // 随池释放，返回对象本身由 ARC 在池外保留，避免跨池返回引发的过度释放。
    NSImage *out = nil;
    @autoreleasepool {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:W
                          pixelsHigh:H
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                         isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:W * 4
                        bitsPerPixel:32];
        if (rep) {
            NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:ctx];

            // 1) 透明底（圆角外保持透明）
            [[NSColor clearColor] setFill];
            NSRectFill(NSMakeRect(0, 0, W, H));

            // 2) 彩色背景：用 tint 原色填圆角矩形（亮度最后统一缩放）
            NSColor *base = [tint colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: tint;
            [base setFill];
            NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, W, H)
                                                                 xRadius:9 yRadius:9];
            [path fill];

            // 3) 白色 SF Symbol 图标居中
            NSImage *icon = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
            if (icon) {
                NSImageSymbolConfiguration *sizeCfg =
                    [NSImageSymbolConfiguration configurationWithPointSize:15
                                                                    weight:NSFontWeightMedium];
                NSImage *sized = [icon imageWithSymbolConfiguration:sizeCfg];
                NSImage *white = nil;
                if (@available(macOS 12.0, *)) {
                    NSImageSymbolConfiguration *colorCfg =
                        [NSImageSymbolConfiguration configurationWithPaletteColors:@[[NSColor whiteColor]]];
                    white = [sized imageWithSymbolConfiguration:colorCfg];
                }
                NSImage *drawIcon = white ?: sized;
                [drawIcon drawInRect:NSMakeRect((W - 22) / 2.0, (H - 22) / 2.0, 22, 22)
                            fromRect:NSZeroRect
                           operation:NSCompositingOperationSourceOver
                            fraction:1.0
                      respectFlipped:YES
                               hints:nil];
            }

            [NSGraphicsContext restoreGraphicsState];

            // 4) 统一按 factor 缩放 RGB（保持 alpha），实现亮度；transparent 区 rgb 仍为 0
            if (factor < 0.999f) {
                unsigned char *data = [rep bitmapData];
                NSInteger rowBytes = [rep bytesPerRow];
                for (int y = 0; y < H; y++) {
                    unsigned char *row = data + (NSInteger)y * rowBytes;
                    for (int x = 0; x < W; x++) {
                        unsigned char *px = row + x * 4;
                        px[0] = (unsigned char)(px[0] * factor);
                        px[1] = (unsigned char)(px[1] * factor);
                        px[2] = (unsigned char)(px[2] * factor);
                    }
                }
            }

            out = [[NSImage alloc] initWithSize:NSMakeSize(W, H)];
            [out addRepresentation:rep];
        }
    }
    return out ?: [[NSImage alloc] init];
}
