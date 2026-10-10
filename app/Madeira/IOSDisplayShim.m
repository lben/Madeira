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
// Milestone 0 (env.MADEIRA_REMAP_TEST): a fixed test layout proves the path on the
// device. The top-left 30%x20% of the frame is drawn again, twice as large, in the
// middle (Lanczos-3), and the top-right corner is reduced to a 48x12 edge
// signature every 6th frame and compared with the first one. 1 = always on,
// 2 = on and off in turns of 10 s so the cost shows in the log. Off by default.

static int madeira_remap_test_mode(void) {
    static int mode = -1;
    if (mode < 0) {
        /* Screen layout milestone-0 test: 1 = the fixed test layout on every game frame, 2 = on and off in turns of 10 s (cost in the log); off otherwise. */
        const char *e = getenv("MADEIRA_REMAP_TEST");
        mode = (e && (*e == '1' || *e == '2')) ? *e - '0' : 0;
        if (mode) fprintf(stderr, "[remap-test] on, mode %d\n", mode);
    }
    return mode;
}

static NSString *const kRemapMSL = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Quad { float4 dst; float4 src; };\n"   // dst in NDC (x0,y0,x1,y1); src in scratch texels
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
"    uint2 c = uint2(clamp(f + float2(i - 2, j - 2), q.src.xy, q.src.zw - 1));\n"
"    acc += w * t.read(c); wsum += w;\n"
"  }\n"
"  return float4(clamp(acc.rgb / wsum, 0.0, 1.0), 1);\n"
"}\n"
"kernel void remap_signature(texture2d<float> t [[texture(0)]], device float *out [[buffer(0)]],\n"
"                            constant float4 &r [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (g.x >= 48 || g.y >= 12) return;\n"
"  float2 a = r.xy + (r.zw - r.xy) * float2(g) / float2(48, 12);\n"
"  float2 b = r.xy + (r.zw - r.xy) * float2(g + 1) / float2(48, 12);\n"
"  float s = 0; int n = 0;\n"
"  for (int y = int(a.y); y < int(ceil(b.y)); y++) for (int x = int(a.x); x < int(ceil(b.x)); x++) {\n"
"    s += dot(t.read(uint2(x, y)).rgb, float3(0.299, 0.587, 0.114)); n++; }\n"
"  out[g.y * 48 + g.x] = s / max(n, 1);\n"
"}\n";

// Normalised NCC of the gradient magnitudes of two 48x12 signatures (1 = same picture).
static float madeira_remap_edge_ncc(const float *a, const float *b) {
    float ea[576], eb[576], ma = 0, mb = 0;
    for (int y = 0; y < 12; y++) for (int x = 0; x < 48; x++) {
        int i = y * 48 + x;
        float ax = (x > 0 && x < 47) ? a[i + 1] - a[i - 1] : 0, ay = (y > 0 && y < 11) ? a[i + 48] - a[i - 48] : 0;
        float bx = (x > 0 && x < 47) ? b[i + 1] - b[i - 1] : 0, by = (y > 0 && y < 11) ? b[i + 48] - b[i - 48] : 0;
        ea[i] = sqrtf(ax * ax + ay * ay); eb[i] = sqrtf(bx * bx + by * by); ma += ea[i]; mb += eb[i];
    }
    ma /= 576; mb /= 576;
    float num = 0, da = 0, db = 0;
    for (int i = 0; i < 576; i++) { float u = ea[i] - ma, v = eb[i] - mb; num += u * v; da += u * u; db += v * v; }
    return num / (sqrtf(da * db) + 1e-6f);
}

static struct {
    pthread_mutex_t lock;
    id<MTLDevice> device;
    id<MTLLibrary> library;
    id<MTLComputePipelineState> signature;
    NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *draw;   // by pixel format
    id<MTLTexture> scratch;
    id<MTLBuffer> sig[3];
    unsigned sigNext;
    float reference[576];
    int haveReference;
    uint64_t frames;
    double phaseStart;
    // per 10 s window: GPU time of the frames' command buffers, signature matches
    double gpuSum[2]; uint64_t gpuCount[2];
    double nccSum, nccMin; uint64_t nccCount;
    int failed;
} g_remap = { .lock = PTHREAD_MUTEX_INITIALIZER };

static BOOL madeira_remap_setup(id<MTLDevice> dev) {
    if (g_remap.failed) return NO;
    if (g_remap.device == dev && g_remap.library) return YES;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kRemapMSL options:nil error:&err];
    id<MTLFunction> sigFn = [lib newFunctionWithName:@"remap_signature"];
    id<MTLComputePipelineState> sig = sigFn ? [dev newComputePipelineStateWithFunction:sigFn error:&err] : nil;
    if (!lib || !sig) {
        fprintf(stderr, "[remap-test] shaders failed: %s\n", err.localizedDescription.UTF8String ?: "?");
        g_remap.failed = 1;
        return NO;
    }
    g_remap.device = dev; g_remap.library = lib; g_remap.signature = sig;
    g_remap.draw = [NSMutableDictionary new];
    for (int i = 0; i < 3; i++) g_remap.sig[i] = [dev newBufferWithLength:576 * sizeof(float) options:MTLResourceStorageModeShared];
    return YES;
}

static id<MTLRenderPipelineState> madeira_remap_pipeline(MTLPixelFormat fmt) {
    id<MTLRenderPipelineState> p = g_remap.draw[@(fmt)];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [g_remap.library newFunctionWithName:@"remap_vs"];
    d.fragmentFunction = [g_remap.library newFunctionWithName:@"remap_fs"];
    d.colorAttachments[0].pixelFormat = fmt;
    NSError *err = nil;
    p = [g_remap.device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) { fprintf(stderr, "[remap-test] no pipeline for format %lu: %s\n", (unsigned long)fmt, err.localizedDescription.UTF8String ?: "?"); return nil; }
    g_remap.draw[@(fmt)] = p;
    return p;
}

static void madeira_remap_log_window(double now) {
    double on = g_remap.gpuCount[1] ? g_remap.gpuSum[1] / g_remap.gpuCount[1] : 0;
    double off = g_remap.gpuCount[0] ? g_remap.gpuSum[0] / g_remap.gpuCount[0] : 0;
    fprintf(stderr, "[remap-test] frames=%llu cmdbuf-gpu on=%.3fms(%llu) off=%.3fms(%llu) signature ncc avg=%.3f min=%.3f (%llu)\n",
            g_remap.frames, on * 1000, g_remap.gpuCount[1], off * 1000, g_remap.gpuCount[0],
            g_remap.nccCount ? g_remap.nccSum / g_remap.nccCount : 0, g_remap.nccCount ? g_remap.nccMin : 0, g_remap.nccCount);
    memset(g_remap.gpuSum, 0, sizeof g_remap.gpuSum); memset(g_remap.gpuCount, 0, sizeof g_remap.gpuCount);
    g_remap.nccSum = 0; g_remap.nccMin = 1; g_remap.nccCount = 0;
    g_remap.phaseStart = now;
}

__attribute__((used, visibility("default")))
void madeira_present_remap(id<MTLCommandBuffer> cb, id<CAMetalDrawable> drawable) {
    int mode = madeira_remap_test_mode();
    if (!mode || !cb || !drawable) return;
    id<MTLTexture> tex = drawable.texture;
    if (!tex || tex.width < 320 || tex.height < 180 || tex.framebufferOnly) return;
    pthread_mutex_lock(&g_remap.lock);
    if (!madeira_remap_setup(tex.device)) { pthread_mutex_unlock(&g_remap.lock); return; }
    double now = CACurrentMediaTime();
    if (!g_remap.phaseStart) { g_remap.phaseStart = now; g_remap.nccMin = 1;
        fprintf(stderr, "[remap-test] first drawable %lux%lu format %lu\n", (unsigned long)tex.width, (unsigned long)tex.height, (unsigned long)tex.pixelFormat); }
    if (now - g_remap.phaseStart >= 10) madeira_remap_log_window(now);
    // mode 2: odd 10 s windows run without the layout
    int on = mode == 1 || ((uint64_t)(now / 10) & 1) == 0;
    uint64_t frame = g_remap.frames++;
    double W = tex.width, H = tex.height;

    // the anchor first: it reads the frame as the game drew it
    if (frame % 6 == 0) {
        id<MTLBuffer> buf = g_remap.sig[g_remap.sigNext++ % 3];
        float r[4] = { (float)(W * 0.85), 0, (float)W, (float)(H * 0.08) };
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:g_remap.signature];
        [ce setTexture:tex atIndex:0];
        [ce setBuffer:buf offset:0 atIndex:0];
        [ce setBytes:r length:sizeof r atIndex:1];
        [ce dispatchThreads:MTLSizeMake(48, 12, 1) threadsPerThreadgroup:MTLSizeMake(16, 4, 1)];
        [ce endEncoding];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (done.status != MTLCommandBufferStatusCompleted) return;
            const float *s = buf.contents;
            pthread_mutex_lock(&g_remap.lock);
            if (!g_remap.haveReference) { memcpy(g_remap.reference, s, sizeof g_remap.reference); g_remap.haveReference = 1; }
            else {
                float n = madeira_remap_edge_ncc(g_remap.reference, s);
                g_remap.nccSum += n; g_remap.nccCount++; if (n < g_remap.nccMin) g_remap.nccMin = n;
            }
            pthread_mutex_unlock(&g_remap.lock);
        }];
    }

    if (on) {
        id<MTLRenderPipelineState> pso = madeira_remap_pipeline(tex.pixelFormat);
        NSUInteger sx = 0, sy = 0, sw = (NSUInteger)(W * 0.30), sh = (NSUInteger)(H * 0.20);
        if (pso && sw && sh) {
            if (!g_remap.scratch || g_remap.scratch.width != sw || g_remap.scratch.height != sh || g_remap.scratch.pixelFormat != tex.pixelFormat) {
                MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:tex.pixelFormat width:sw height:sh mipmapped:NO];
                d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
                g_remap.scratch = [tex.device newTextureWithDescriptor:d];
            }
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sx, sy, 0)
                       sourceSize:MTLSizeMake(sw, sh, 1) toTexture:g_remap.scratch destinationSlice:0
                 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = tex;
            rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:pso];
            [enc setFragmentTexture:g_remap.scratch atIndex:0];
            // destination: x 35%..95%, y 30%..70% (NDC y grows upwards)
            float q[8] = { -0.30f, 0.40f, 0.90f, -0.40f, 0, 0, (float)sw, (float)sh };
            [enc setVertexBytes:q length:sizeof q atIndex:0];
            [enc setFragmentBytes:q length:sizeof q atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [enc endEncoding];
        }
    }
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        double t = done.GPUEndTime - done.GPUStartTime;
        if (t <= 0 || t > 1) return;
        pthread_mutex_lock(&g_remap.lock);
        g_remap.gpuSum[on] += t; g_remap.gpuCount[on]++;
        pthread_mutex_unlock(&g_remap.lock);
    }];
    pthread_mutex_unlock(&g_remap.lock);
}
