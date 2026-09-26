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
// 亮度工具：对 NSImage 做像素级缩放（保持 alpha，RGB × factor）
//   factor = brightness/100：0 → 全黑，1.0 → 原样
//   返回新建 NSImage，或失败时返回原图
// ---------------------------------------------------------------------------
NSImage *TB_dimImage(NSImage *image, float factor) {
    if (!image) return image;
    if (factor >= 0.999f) return image;

    const int W = 48, H = 48;
    // 预分配 RGBA 像素缓冲（让 bitmapDataPlanes 直接写到这里，
    // ObjC 侧可以直接访问裸指针做像素缩放，绕开 Swift 的指针 API 坑）
    unsigned char *buf = (unsigned char *)malloc((size_t)W * H * 4);
    if (!buf) return image;
    memset(buf, 0, (size_t)W * H * 4);
    unsigned char *planes[1] = { buf };

    NSImage *result = image;   // 失败兜底：返回原图
    @autoreleasepool {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:planes
                          pixelsWide:W
                          pixelsHigh:H
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                         isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:W * 4
                        bitsPerPixel:W * H * 4];
        if (rep) {
            NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:ctx];
            [image drawAtPoint:NSMakePoint(0, 0)
                     fromRect:NSZeroRect
                    operation:NSCompositingOperationCopy
                     fraction:1.0];
            [NSGraphicsContext restoreGraphicsState];

            // 逐像素缩放 RGB（保持 alpha 不变 → 透明区域仍透明）
            for (int y = 0; y < H; y++) {
                for (int x = 0; x < W; x++) {
                    int o = y * W * 4 + x * 4;
                    buf[o + 0] = (unsigned char)TB_MIN(255.0, (double)buf[o + 0] * factor);
                    buf[o + 1] = (unsigned char)TB_MIN(255.0, (double)buf[o + 1] * factor);
                    buf[o + 2] = (unsigned char)TB_MIN(255.0, (double)buf[o + 2] * factor);
                }
            }
            NSImage *out = [[NSImage alloc] initWithSize:image.size];
            [out addRepresentation:rep];
            result = out;
        }
    }
    free(buf);
    return result;
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
