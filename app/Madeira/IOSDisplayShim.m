// IOSDisplayShim.m — iOS stand-in for Wine's mac driver, used by DXMT.
//
// DXMT (src/winemetal/unix/winemetal_unix.c) looks up this API via
// dlsym(RTLD_DEFAULT, "macdrv_functions") to obtain a CAMetalLayer for a
// given HWND. We export those symbols from the main binary so DXMT finds
// them in the same process.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <pthread.h>

#include "IOSDisplayShim.h"

// --- Types mirroring DXMT's expectations (see winemetal_unix.c lines ~1524) ---

typedef struct macdrv_opaque_metal_device *macdrv_metal_device;
typedef struct macdrv_opaque_metal_view   *macdrv_metal_view;
typedef struct macdrv_opaque_metal_layer  *macdrv_metal_layer;
typedef struct macdrv_opaque_view         *macdrv_view;
typedef struct macdrv_opaque_window       *macdrv_window;
typedef struct opaque_HWND                *HWND;

struct macdrv_win_data {
    HWND         hwnd;
    macdrv_window cocoa_window;
    macdrv_view   cocoa_view;
    macdrv_view   client_cocoa_view;
};

struct macdrv_functions_t {
    void (*macdrv_init_display_devices)(BOOL);
    struct macdrv_win_data *(*get_win_data)(HWND hwnd);
    void (*release_win_data)(struct macdrv_win_data *data);
    macdrv_window (*macdrv_get_cocoa_window)(HWND hwnd, BOOL require_on_screen);
    macdrv_metal_device (*macdrv_create_metal_device)(void);
    void (*macdrv_release_metal_device)(macdrv_metal_device d);
    macdrv_metal_view (*macdrv_view_create_metal_view)(macdrv_view v, macdrv_metal_device d);
    macdrv_metal_layer (*macdrv_view_get_metal_layer)(macdrv_metal_view v);
    void (*macdrv_view_release_metal_view)(macdrv_metal_view v);
    void (*on_main_thread)(dispatch_block_t b);
};

// --- iOS-side state: one layer shared by the whole process ---

static CAMetalLayer *g_layer = nil;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

void madeira_display_set_layer(CAMetalLayer *layer) {
    pthread_mutex_lock(&g_lock);
    g_layer = layer;
    pthread_mutex_unlock(&g_lock);
}

// --- The guest's virtual monitor ---------------------------------------
//
// The front end lays out the presented layer and maps touches in guest
// pixels, so it needs the monitor size win32u uses. win32u reads
// MADEIRA_SCREEN_W/H once per session (sysparams_ios.c, ios_screen_size), so
// that is the seed; sysparams_ios.c calls winios_display_mode_changed() when
// a program changes the display mode (ios_publish_screen_size), and the
// front end calls it when it chooses a session's size.

static int g_screen_w, g_screen_h;   // 0 until something publishes a size
static pthread_mutex_t g_screen_lock = PTHREAD_MUTEX_INITIALIZER;

NSString * const MadeiraDisplayModeChangedNotification = @"MadeiraDisplayModeChanged";

void winios_screen_size(int *w, int *h) {
    pthread_mutex_lock(&g_screen_lock);
    int sw = g_screen_w, sh = g_screen_h;
    pthread_mutex_unlock(&g_screen_lock);
    if (sw <= 0 || sh <= 0) {
        // Nothing published: the session default, read each time because the
        // app sets it per launch.
        const char *we = getenv("MADEIRA_SCREEN_W"), *he = getenv("MADEIRA_SCREEN_H");
        sw = (we && atoi(we) > 0) ? atoi(we) : 1024;
        sh = (he && atoi(he) > 0) ? atoi(he) : 768;
    }
    if (w) *w = sw;
    if (h) *h = sh;
}

void winios_display_mode_changed(int w, int h) {
    if (w <= 0 || h <= 0) return;
    pthread_mutex_lock(&g_screen_lock);
    int changed = (g_screen_w != w || g_screen_h != h);
    g_screen_w = w;
    g_screen_h = h;
    pthread_mutex_unlock(&g_screen_lock);
    if (!changed) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:MadeiraDisplayModeChangedNotification object:nil];
    });
}

// --- DXMT display-rate hook -----------------------------------------------
//
// DXMT from willfaust/dxmt#1 on defines madeira_set_display_max_fps() (the
// panel and intent rates for its [frame] line) together with the 30 FPS cap
// (vsync mode 3). main's DXMT has neither. This weak no-op definition keeps
// the app linking against either: when DXMT's strong definition is linked it
// replaces this one, and this one never runs. When it does run, DXMT lacks the
// 30 FPS cap too (mode 3 would present uncapped), so the front end hides it.

static volatile int g_dxmt_display_pacing_missing;

__attribute__((weak)) void madeira_set_display_max_fps(int panel_hz, int intent_hz) {
    (void)panel_hz;
    (void)intent_hz;
    g_dxmt_display_pacing_missing = 1;
}

int madeira_dxmt_has_display_pacing(void) {
    return !g_dxmt_display_pacing_missing;
}

// DXMT with the 40 FPS cap (vsync mode 4) defines madeira_dxmt_has_40_cap()
// returning 1. A DXMT without it would present mode 4 uncapped, so this weak
// fallback says no and the front end does not offer 40.
__attribute__((weak)) int madeira_dxmt_has_40_cap(void) {
    return 0;
}

// --- macdrv_* implementations ---

// DXMT only dereferences client_cocoa_view (passing it straight back to
// macdrv_view_create_metal_view), so we use that field to carry the HWND
// through: desktop mode needs it to pick the right window's layer. One
// static struct suffices — DXMT's get/create/release sequence is not
// concurrent per-process, and the value is consumed before release.
static struct macdrv_win_data g_fake_win_data = {
    .hwnd              = NULL,
    .cocoa_window      = NULL,
    .cocoa_view        = (macdrv_view)(uintptr_t)0x1,
    .client_cocoa_view = (macdrv_view)(uintptr_t)0x1,
};

static struct macdrv_win_data *my_get_win_data(HWND hwnd) {
    g_fake_win_data.hwnd = hwnd;
    g_fake_win_data.client_cocoa_view = (macdrv_view)hwnd;
    return &g_fake_win_data;
}

static void my_release_win_data(struct macdrv_win_data *data) {
    (void)data;
}

static int madeira_desktop_mode(void) {
    static int desk = -1;
    if (desk < 0) {
        const char *d = getenv("MADEIRA_DESKTOP");
        desk = d && *d == '1';
    }
    return desk;
}

// Winios.m compositor: per-window CAMetalLayer inside the window's
// compositor layer (desktop mode only).
extern CAMetalLayer *winios_metal_layer_for_hwnd(void *hwnd);
// Game sessions: the window a swapchain presents from is the game's own;
// Winios.m's game-mode window overlay must not draw its GDI bits.
extern void winios_note_game_metal_hwnd(void *hwnd);

static macdrv_metal_device my_create_metal_device(void) {
    // DXMT also has a separate code path that creates its own MTLDevice;
    // this is only called by a Wine-flavoured API we don't hit. Return a
    // non-null sentinel so the caller doesn't think it's a failure.
    return (macdrv_metal_device)(uintptr_t)0x1;
}

static void my_release_metal_device(macdrv_metal_device d) {
    (void)d;
}

// The critical two: return a "view" handle that maps to the CAMetalLayer.
// We pack the layer pointer directly. `v` carries the swapchain's HWND
// (see my_get_win_data). Desktop mode: per-window layer in the desktop
// compositor. Game mode: the fullscreen singleton, exactly as before.
static macdrv_metal_view my_view_create_metal_view(macdrv_view v, macdrv_metal_device d) {
    (void)d;
    if (madeira_desktop_mode()) {
        CAMetalLayer *layer = winios_metal_layer_for_hwnd((void *)v);
        if (!layer) {
            NSLog(@"[madeira-display] desktop metal layer creation failed for hwnd=%p", (void *)v);
            return NULL;
        }
        fprintf(stderr, "[madeira-display] desktop metal view for hwnd=%p layer=%p\n", (void *)v, layer);
        fflush(stderr);
        return (macdrv_metal_view)CFBridgingRetain(layer);
    }
    pthread_mutex_lock(&g_lock);
    CAMetalLayer *layer = g_layer;
    pthread_mutex_unlock(&g_lock);
    if (!layer) {
        NSLog(@"[madeira-display] view_create_metal_view called before layer registered!");
        return NULL;
    }
    winios_note_game_metal_hwnd((void *)v);
    return (macdrv_metal_view)CFBridgingRetain(layer);
}

static macdrv_metal_layer my_view_get_metal_layer(macdrv_metal_view v) {
    return (macdrv_metal_layer)v;
}

static void my_view_release_metal_view(macdrv_metal_view v) {
    if (v) CFBridgingRelease((CFTypeRef)v);
}

static void my_on_main_thread(dispatch_block_t b) {
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

// --- Exported symbols (dlsym RTLD_DEFAULT finds these in the main binary) ---
//
// `used` is LOAD-BEARING, not decoration. Nothing in this program references
// these by name: DXMT's winemetal_unix.c reaches them only through
// dlsym(RTLD_DEFAULT, "macdrv_functions"), which the linker cannot see. Under a
// Release link (-dead_strip) they are therefore unreferenced and get removed,
// visibility("default") notwithstanding -- visibility governs whether a symbol
// that SURVIVES is exported, not whether it survives. `used` emits .no_dead_strip
// so the linker keeps them.
//
// That is exactly how Thumper broke on 2026-08-08: the host app was rebuilt
// Release instead of Debug, these six symbols vanished from the binary, DXMT's
// lookup returned NULL and d3d11_swapchain aborted with "your Wine has no
// exported symbols needed by DXMT" -> exit code 3 -> white screen.
//
// `used` alone proved sufficient: after adding it, all six land in the export
// trie of a Release build, so no -u roots or -export_dynamic are needed. Do not
// assume that stays true -- VERIFY BY CONTENT after any build or link change:
//   xcrun dyld_info -exports Madeira.app/Madeira | grep macdrv_functions
// If that prints nothing, Thumper will exit 3 with a white screen.

__attribute__((used, visibility("default")))
struct macdrv_functions_t macdrv_functions = {
    .macdrv_init_display_devices    = NULL,
    .get_win_data                   = my_get_win_data,
    .release_win_data               = my_release_win_data,
    .macdrv_get_cocoa_window        = NULL,
    .macdrv_create_metal_device     = my_create_metal_device,
    .macdrv_release_metal_device    = my_release_metal_device,
    .macdrv_view_create_metal_view  = my_view_create_metal_view,
    .macdrv_view_get_metal_layer    = my_view_get_metal_layer,
    .macdrv_view_release_metal_view = my_view_release_metal_view,
    .on_main_thread                 = my_on_main_thread,
};

// Also export individual symbols as a fallback (DXMT checks both paths).
__attribute__((used, visibility("default")))
struct macdrv_win_data *get_win_data(HWND hwnd) { return my_get_win_data(hwnd); }

__attribute__((used, visibility("default")))
void release_win_data(struct macdrv_win_data *data) { my_release_win_data(data); }

__attribute__((used, visibility("default")))
macdrv_metal_view macdrv_view_create_metal_view(macdrv_view v, macdrv_metal_device d) {
    return my_view_create_metal_view(v, d);
}

__attribute__((used, visibility("default")))
macdrv_metal_layer macdrv_view_get_metal_layer(macdrv_metal_view v) {
    return my_view_get_metal_layer(v);
}

__attribute__((used, visibility("default")))
void macdrv_view_release_metal_view(macdrv_metal_view v) {
    my_view_release_metal_view(v);
}

// --- Screen layouts: the last step on a game frame -------------------------
//
// DXMT's winemetal (madeira_present_remap, weak there) calls this for every game
// drawable (D3D9/10/11 through dxmt::Presenter, D3D12 through madeira-d3d12) on the
// encode thread, before it presents it. Work encoded here lands in the game's own
// command buffer, after the frame and before the present.
//
// A layout is a list of zones in the frame's normalised coordinates (0..1, origin
// top-left): each copies its source rect to its destination rect (Lanczos-3), and
// may black out the source. All sources are copied out first, so zones read the
// frame as the game drew it. The front end sets the zones of the running game
// (ScreenLayouts in Library.swift) and asks for one frame for its editor.

#define MADEIRA_REMAP_MAX_ZONES 16

static NSString *const kRemapMSL = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Quad { float4 dst; float4 src; };\n"   // dst in NDC (x0,y0,x1,y1); src in source texels
"struct VOut { float4 pos [[position]]; float2 uv; };\n"
"vertex VOut remap_vs(uint vid [[vertex_id]], constant Quad &q [[buffer(0)]]) {\n"
"  float2 c = float2(vid & 1, vid >> 1);\n"
"  VOut o; o.pos = float4(mix(q.dst.xy, q.dst.zw, c), 0, 1); o.uv = mix(q.src.xy, q.src.zw, c); return o;\n"
"}\n"
"static float lz(float x) { x = abs(x); if (x < 1e-5) return 1; if (x >= 3) return 0;\n"
"  float px = M_PI_F * x; return 3 * sin(px) * sin(px / 3) / (px * px); }\n"
"fragment float4 remap_fs(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant Quad &q [[buffer(0)]]) {\n"
"  float2 p = in.uv - 0.5, f = floor(p), fr = p - f;\n"
"  float wx[6], wy[6];\n"
"  for (int k = 0; k < 6; k++) { wx[k] = lz(k - 2 - fr.x); wy[k] = lz(k - 2 - fr.y); }\n"
"  float4 acc = 0; float wsum = 0;\n"
"  for (int j = 0; j < 6; j++) for (int i = 0; i < 6; i++) {\n"
"    float w = wx[i] * wy[j];\n"
"    uint2 c = uint2(clamp(f + float2(i - 2, j - 2), q.src.xy, q.src.zw - 1));\n"   // reads stay inside the source rect
"    acc += w * t.read(c); wsum += w;\n"
"  }\n"
"  return float4(clamp(acc.rgb / wsum, 0.0, 1.0), 1);\n"
"}\n"
"fragment float4 remap_fill_fs(VOut in [[stage_in]]) { return float4(0, 0, 0, 1); }\n";

typedef struct { float sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, hide; } MadeiraRemapZone;

static struct {
    pthread_mutex_t lock;
    _Atomic int busy;   // zones set or a capture waiting: the hook does nothing without it
    MadeiraRemapZone zones[MADEIRA_REMAP_MAX_ZONES];
    int count;
    MadeiraFrameCapture capture;
    id<MTLDevice> device;
    id<MTLLibrary> library;
    NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *pipelines;   // "fs/format"
    id<MTLTexture> scratch;
    int failed;
} g_remap = { .lock = PTHREAD_MUTEX_INITIALIZER };

static void madeira_remap_update_busy(void) {
    g_remap.busy = g_remap.count > 0 || g_remap.capture != nil;
}

void madeira_remap_set_zones(const float *zones, int count) {
    if (count < 0 || !zones) count = 0;
    if (count > MADEIRA_REMAP_MAX_ZONES) count = MADEIRA_REMAP_MAX_ZONES;
    pthread_mutex_lock(&g_remap.lock);
    int kept = 0;
    for (int i = 0; i < count; i++) {
        MadeiraRemapZone z;
        memcpy(&z, zones + i * 9, sizeof z);
        // normalised, non-empty, inside the frame
        if (!(z.sx0 >= 0 && z.sy0 >= 0 && z.sx1 <= 1 && z.sy1 <= 1 && z.sx1 > z.sx0 && z.sy1 > z.sy0 &&
              z.dx0 >= 0 && z.dy0 >= 0 && z.dx1 <= 1 && z.dy1 <= 1 && z.dx1 > z.dx0 && z.dy1 > z.dy0)) continue;
        g_remap.zones[kept++] = z;
    }
    g_remap.count = kept;
    madeira_remap_update_busy();
    pthread_mutex_unlock(&g_remap.lock);
    fprintf(stderr, "[screen-layout] %d zone(s) applied\n", kept);
}

void madeira_remap_capture(MadeiraFrameCapture done) {
    pthread_mutex_lock(&g_remap.lock);
    MadeiraFrameCapture previous = g_remap.capture;
    g_remap.capture = [done copy];
    madeira_remap_update_busy();
    pthread_mutex_unlock(&g_remap.lock);
    if (previous) dispatch_async(dispatch_get_main_queue(), ^{ previous(NULL); });
}

static BOOL madeira_remap_setup(id<MTLDevice> dev) {
    if (g_remap.failed) return NO;
    if (g_remap.device == dev && g_remap.library) return YES;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kRemapMSL options:nil error:&err];
    if (!lib) {
        fprintf(stderr, "[screen-layout] shaders failed: %s\n", err.localizedDescription.UTF8String ?: "?");
        g_remap.failed = 1;
        return NO;
    }
    g_remap.device = dev; g_remap.library = lib; g_remap.scratch = nil;
    g_remap.pipelines = [NSMutableDictionary new];
    return YES;
}

static id<MTLRenderPipelineState> madeira_remap_pipeline(NSString *fs, MTLPixelFormat fmt) {
    NSString *key = [NSString stringWithFormat:@"%@/%lu", fs, (unsigned long)fmt];
    id<MTLRenderPipelineState> p = g_remap.pipelines[key];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [g_remap.library newFunctionWithName:@"remap_vs"];
    d.fragmentFunction = [g_remap.library newFunctionWithName:fs];
    d.colorAttachments[0].pixelFormat = fmt;
    NSError *err = nil;
    p = [g_remap.device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) { fprintf(stderr, "[screen-layout] no %s pipeline for format %lu: %s\n", fs.UTF8String, (unsigned long)fmt, err.localizedDescription.UTF8String ?: "?"); return nil; }
    g_remap.pipelines[key] = p;
    return p;
}

// One quad: destination in pixels of a W x H target, source in texels of the bound texture.
static void madeira_remap_quad(id<MTLRenderCommandEncoder> enc, double W, double H,
                               double dx0, double dy0, double dx1, double dy1,
                               double sx0, double sy0, double sx1, double sy1) {
    float q[8] = { (float)(dx0 / W * 2 - 1), (float)(1 - dy0 / H * 2), (float)(dx1 / W * 2 - 1), (float)(1 - dy1 / H * 2),
                   (float)sx0, (float)sy0, (float)sx1, (float)sy1 };
    [enc setVertexBytes:q length:sizeof q atIndex:0];
    [enc setFragmentBytes:q length:sizeof q atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

// The frame as the game drew it, as an 8-bit image, for the editor.
static void madeira_remap_encode_capture(id<MTLCommandBuffer> cb, id<MTLTexture> tex, MadeiraFrameCapture done) {
    NSUInteger W = tex.width, H = tex.height;
    id<MTLRenderPipelineState> pso = madeira_remap_pipeline(@"remap_fs", MTLPixelFormatBGRA8Unorm);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [tex.device newTextureWithDescriptor:d];
    id<MTLBuffer> bytes = [tex.device newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
    if (!pso || !target || !bytes) { dispatch_async(dispatch_get_main_queue(), ^{ done(NULL); }); return; }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pso];
    [enc setFragmentTexture:tex atIndex:0];
    madeira_remap_quad(enc, W, H, 0, 0, W, H, 0, 0, W, H);   // 1:1, so Lanczos copies texels exactly
    [enc endEncoding];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                 toBuffer:bytes destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
    [blit endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        CGImageRef image = NULL;
        if (finished.status == MTLCommandBufferStatusCompleted) {
            CFDataRef data = CFDataCreate(NULL, bytes.contents, (CFIndex)(W * H * 4));
            CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            image = CGImageCreate(W, H, 8, 32, W * 4, cs, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                  provider, NULL, false, kCGRenderingIntentDefault);
            CGColorSpaceRelease(cs); CGDataProviderRelease(provider); CFRelease(data);
        }
        fprintf(stderr, "[screen-layout] frame captured %lux%lu: %s\n", (unsigned long)W, (unsigned long)H, image ? "ok" : "failed");
        dispatch_async(dispatch_get_main_queue(), ^{ done(image); if (image) CGImageRelease(image); });
    }];
}

__attribute__((used, visibility("default")))
void madeira_present_remap(id<MTLCommandBuffer> cb, id<CAMetalDrawable> drawable) {
    if (!g_remap.busy || !cb || !drawable) return;
    id<MTLTexture> tex = drawable.texture;
    if (!tex || tex.width < 320 || tex.height < 180 || tex.framebufferOnly) return;
    pthread_mutex_lock(&g_remap.lock);
    if (!madeira_remap_setup(tex.device)) { pthread_mutex_unlock(&g_remap.lock); return; }
    MadeiraFrameCapture capture = g_remap.capture;
    g_remap.capture = nil;
    madeira_remap_update_busy();
    if (capture) madeira_remap_encode_capture(cb, tex, capture);

    int n = g_remap.count;
    double W = tex.width, H = tex.height;
    NSUInteger sx[MADEIRA_REMAP_MAX_ZONES], sy[MADEIRA_REMAP_MAX_ZONES], sw[MADEIRA_REMAP_MAX_ZONES], sh[MADEIRA_REMAP_MAX_ZONES];
    NSUInteger packW = 0, packH = 0;
    for (int i = 0; i < n; i++) {
        MadeiraRemapZone z = g_remap.zones[i];
        // source edges on the nearest pixel (a float 492/648 times 648 is 491.99997)
        sx[i] = (NSUInteger)MIN(lround(z.sx0 * W), (long)W - 1); sy[i] = (NSUInteger)MIN(lround(z.sy0 * H), (long)H - 1);
        sw[i] = (NSUInteger)MAX(MIN(lround(z.sx1 * W), (long)W) - (long)sx[i], 1);
        sh[i] = (NSUInteger)MAX(MIN(lround(z.sy1 * H), (long)H) - (long)sy[i], 1);
        packW += sw[i]; packH = MAX(packH, sh[i]);
    }
    id<MTLRenderPipelineState> draw = n ? madeira_remap_pipeline(@"remap_fs", tex.pixelFormat) : nil;
    id<MTLRenderPipelineState> fill = n ? madeira_remap_pipeline(@"remap_fill_fs", tex.pixelFormat) : nil;
    if (n && draw && fill && packW && packH) {
        // the sources side by side in one scratch texture, copied before anything is drawn
        if (!g_remap.scratch || g_remap.scratch.width < packW || g_remap.scratch.height < packH || g_remap.scratch.pixelFormat != tex.pixelFormat) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:tex.pixelFormat
                                       width:MAX(packW, g_remap.scratch.width) height:MAX(packH, g_remap.scratch.height) mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
            g_remap.scratch = [tex.device newTextureWithDescriptor:d];
        }
        id<MTLTexture> scratch = g_remap.scratch;
        if (!scratch) { pthread_mutex_unlock(&g_remap.lock); return; }
        NSUInteger at[MADEIRA_REMAP_MAX_ZONES], x = 0;
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        for (int i = 0; i < n; i++) {
            [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sx[i], sy[i], 0)
                       sourceSize:MTLSizeMake(sw[i], sh[i], 1) toTexture:scratch destinationSlice:0
                 destinationLevel:0 destinationOrigin:MTLOriginMake(x, 0, 0)];
            at[i] = x; x += sw[i];
        }
        [blit endEncoding];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex;
        rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:fill];
        for (int i = 0; i < n; i++)
            if (g_remap.zones[i].hide) madeira_remap_quad(enc, W, H, sx[i], sy[i], sx[i] + sw[i], sy[i] + sh[i], 0, 0, 1, 1);
        [enc setRenderPipelineState:draw];
        [enc setFragmentTexture:scratch atIndex:0];
        for (int i = 0; i < n; i++) {
            MadeiraRemapZone z = g_remap.zones[i];
            madeira_remap_quad(enc, W, H, z.dx0 * W, z.dy0 * H, z.dx1 * W, z.dy1 * H, at[i], 0, at[i] + sw[i], sh[i]);
        }
        [enc endEncoding];
    }
    pthread_mutex_unlock(&g_remap.lock);
}
