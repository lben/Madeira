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
// A game has up to 8 layouts, one per screen of the game. A layout is a list of
// zones in the frame's normalised coordinates (0..1, origin top-left): each copies
// its source rect to its destination rect, smooth (Lanczos-3) or sharp (square
// pixels with anti-aliased edges, for pixel art), and may hide the source, black or
// blended from the pixels around it (a Coons patch of its border). All sources are copied out first, so zones read the frame as the game
// drew it. A layout may have an anchor, a rect of the frame with the 48x12 luma
// signature it had when the player chose it: every 6th frame the anchors are read
// again on the GPU, and the layout whose anchor matches best (edge NCC >= 0.45,
// the same winner twice in a row) is drawn; when none matches, the first layout
// without an anchor, if any. The front end sets the running game's layouts
// (ScreenLayouts in Library.swift) and asks for one frame for its editor.

#define MADEIRA_REMAP_MAX_ZONES 16
#define MADEIRA_REMAP_MAX_LAYOUTS 8
#define MADEIRA_REMAP_SIG 576          /* 48 x 12 */
#define MADEIRA_REMAP_MATCH 0.45f

static NSString *const kRemapMSL = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Quad { float4 dst; float4 src; float4 p; };\n"   // dst in NDC (x0,y0,x1,y1); src in source texels; p per shader
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
"fragment float4 remap_fill_fs(VOut in [[stage_in]]) { return float4(0, 0, 0, 1); }\n"
// sharp: each source texel a square of p.xy destination pixels, its edges anti-aliased
"fragment float4 remap_sharp_fs(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant Quad &q [[buffer(0)]]) {\n"
"  float2 p = in.uv - 0.5, i = floor(p), f = clamp((p - i - 0.5) * q.p.xy + 0.5, 0.0, 1.0);\n"
"  float2 lo = q.src.xy, hi = q.src.zw - 1;\n"
"  float4 a = t.read(uint2(clamp(i, lo, hi))), b = t.read(uint2(clamp(i + float2(1, 0), lo, hi)));\n"
"  float4 c = t.read(uint2(clamp(i + float2(0, 1), lo, hi))), d = t.read(uint2(clamp(i + float2(1, 1), lo, hi)));\n"
"  return float4(mix(mix(a, b, f.x), mix(c, d, f.x), f.y).rgb, 1);\n"
"}\n"
// blend: the hidden rect filled from its border (p = left, top, right, bottom texel of the ring),
// each border averaged along itself first so lines and text crossing it do not streak
"static float4 along(texture2d<float> t, float2 at, float2 step, int r, float2 lo, float2 hi) {\n"
"  float4 s = 0; for (int k = -r; k <= r; k++) s += t.read(uint2(clamp(at + step * k, lo, hi))); return s / (2 * r + 1);\n"
"}\n"
"fragment float4 remap_blend_fs(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant Quad &q [[buffer(0)]]) {\n"
"  float2 lo = q.p.xy, hi = q.p.zw;\n"
"  float2 p = clamp(floor(in.uv), lo, hi);\n"
"  float2 w = (p - lo) / max(hi - lo, float2(1));\n"
"  int r = int(clamp(min(hi.x - lo.x, hi.y - lo.y) / 4, 2.0, 16.0));\n"
"  float4 top = along(t, float2(p.x, lo.y), float2(1, 0), r, lo, hi), bottom = along(t, float2(p.x, hi.y), float2(1, 0), r, lo, hi);\n"
"  float4 left = along(t, float2(lo.x, p.y), float2(0, 1), r, lo, hi), right = along(t, float2(hi.x, p.y), float2(0, 1), r, lo, hi);\n"
"  float4 c00 = along(t, lo, float2(1, 0), r, lo, hi), c10 = along(t, float2(hi.x, lo.y), float2(1, 0), r, lo, hi);\n"
"  float4 c01 = along(t, float2(lo.x, hi.y), float2(1, 0), r, lo, hi), c11 = along(t, hi, float2(1, 0), r, lo, hi);\n"
"  float4 edges = mix(top, bottom, w.y) + mix(left, right, w.x);\n"
"  float4 corners = mix(mix(c00, c10, w.x), mix(c01, c11, w.x), w.y);\n"
"  return float4(clamp((edges - corners).rgb, 0.0, 1.0), 1);\n"
"}\n"
// one 48x12 box-averaged luma signature per anchor (pixel rects), z = anchor
"kernel void remap_signature(texture2d<float> t [[texture(0)]], device float *out [[buffer(0)]],\n"
"                            constant float4 *rects [[buffer(1)]], uint3 g [[thread_position_in_grid]]) {\n"
"  if (g.x >= 48 || g.y >= 12) return;\n"
"  float4 r = rects[g.z];\n"
"  float2 a = r.xy + (r.zw - r.xy) * float2(g.xy) / float2(48, 12);\n"
"  float2 b = r.xy + (r.zw - r.xy) * float2(g.xy + 1) / float2(48, 12);\n"
"  float s = 0; int n = 0;\n"
"  int y1 = min(int(ceil(b.y)), int(t.get_height())), x1 = min(int(ceil(b.x)), int(t.get_width()));\n"   // as ScreenLayouts.signature
"  for (int y = int(a.y); y < y1; y++) for (int x = int(a.x); x < x1; x++) {\n"
"    s += dot(t.read(uint2(x, y)).rgb, float3(0.299, 0.587, 0.114)); n++; }\n"
"  out[g.z * 576 + g.y * 48 + g.x] = s / max(n, 1);\n"
"}\n";

// hide: 0 no, 1 black, 2 blended; sharp: 1 square pixels, 0 Lanczos
typedef struct { float sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, hide, sharp; } MadeiraRemapZone;
typedef struct {
    int first, count;                     // its zones in g_remap.zones
    int anchored;
    float anchor[4];                      // normalised x0 y0 x1 y1
    float reference[MADEIRA_REMAP_SIG];
    float score;                          // the last match, -1 before the first
} MadeiraRemapLayout;

static struct {
    pthread_mutex_t lock;
    _Atomic int busy;   // layouts set or a capture waiting: the hook does nothing without it
    MadeiraRemapZone zones[MADEIRA_REMAP_MAX_ZONES * MADEIRA_REMAP_MAX_LAYOUTS];   // 16 per layout
    int zoneCount;
    MadeiraRemapLayout layouts[MADEIRA_REMAP_MAX_LAYOUTS];
    int layoutCount, anchoredCount, fallback;   // fallback: the first layout without an anchor, or -1
    _Atomic int active;                         // the layout drawn, or -1
    int pending, pendingRuns;
    uint64_t frames, generation;           // generation: bumped by every set_layouts
    id<MTLBuffer> signatures[3];
    unsigned signatureNext;
    MadeiraFrameCapture capture;
    id<MTLDevice> device;
    id<MTLLibrary> library;
    NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *pipelines;   // "fs/format"
    id<MTLTexture> scratch;
    id<MTLComputePipelineState> signature;
    int failed;
} g_remap = { .lock = PTHREAD_MUTEX_INITIALIZER };

static void madeira_remap_update_busy(void) {
    g_remap.busy = g_remap.layoutCount > 0 || g_remap.capture != nil;
}

static int madeira_remap_rect_ok(float x0, float y0, float x1, float y1) {
    return x0 >= 0 && y0 >= 0 && x1 <= 1 && y1 <= 1 && x1 > x0 && y1 > y0;   // false for NaN too
}

void madeira_remap_set_layouts(int layoutCount, const int *zoneCounts, const float *zones,
                               const float *anchors, const float *signatures) {
    if (layoutCount < 0 || !zoneCounts || !anchors || !signatures) layoutCount = 0;
    if (layoutCount > MADEIRA_REMAP_MAX_LAYOUTS) layoutCount = MADEIRA_REMAP_MAX_LAYOUTS;
    pthread_mutex_lock(&g_remap.lock);
    int z = 0, read = 0, anchored = 0;
    g_remap.fallback = -1;
    for (int l = 0; l < layoutCount; l++) {
        MadeiraRemapLayout *L = &g_remap.layouts[l];
        L->first = z; L->count = 0; L->score = -1;
        for (int i = 0; i < zoneCounts[l]; i++, read++) {
            MadeiraRemapZone c;
            memcpy(&c, zones + read * 10, sizeof c);
            if (L->count >= MADEIRA_REMAP_MAX_ZONES || !madeira_remap_rect_ok(c.sx0, c.sy0, c.sx1, c.sy1) ||
                !madeira_remap_rect_ok(c.dx0, c.dy0, c.dx1, c.dy1)) continue;
            g_remap.zones[z++] = c; L->count++;
        }
        const float *a = anchors + l * 4;
        L->anchored = madeira_remap_rect_ok(a[0], a[1], a[2], a[3]);
        if (L->anchored) {
            memcpy(L->anchor, a, sizeof L->anchor);
            memcpy(L->reference, signatures + l * MADEIRA_REMAP_SIG, sizeof L->reference);
            anchored++;
        } else if (g_remap.fallback < 0) g_remap.fallback = l;
    }
    g_remap.zoneCount = z;
    g_remap.layoutCount = layoutCount;
    g_remap.generation++;
    g_remap.anchoredCount = anchored;
    // Until the anchors are read, the layout without one.
    g_remap.active = g_remap.fallback;
    g_remap.pending = g_remap.fallback; g_remap.pendingRuns = 0;
    madeira_remap_update_busy();
    pthread_mutex_unlock(&g_remap.lock);
    fprintf(stderr, "[screen-layout] %d layout(s), %d with an anchor, %d zone(s) applied\n", layoutCount, anchored, z);
}

int madeira_remap_active_layout(void) { return g_remap.active; }

float madeira_remap_layout_score(int layout) {
    pthread_mutex_lock(&g_remap.lock);
    float s = (layout >= 0 && layout < g_remap.layoutCount && g_remap.layouts[layout].anchored) ? g_remap.layouts[layout].score : -1;
    pthread_mutex_unlock(&g_remap.lock);
    return s;
}

// Normalised cross-correlation of the gradient magnitudes of two 48x12 signatures
// (1 = the same picture; a flat signature, all one colour, matches nothing).
float madeira_remap_signature_match(const float *a, const float *b) {
    float ea[MADEIRA_REMAP_SIG], eb[MADEIRA_REMAP_SIG], ma = 0, mb = 0;
    for (int y = 0; y < 12; y++) for (int x = 0; x < 48; x++) {
        int i = y * 48 + x;
        float ax = (x > 0 && x < 47) ? a[i + 1] - a[i - 1] : 0, ay = (y > 0 && y < 11) ? a[i + 48] - a[i - 48] : 0;
        float bx = (x > 0 && x < 47) ? b[i + 1] - b[i - 1] : 0, by = (y > 0 && y < 11) ? b[i + 48] - b[i - 48] : 0;
        ea[i] = sqrtf(ax * ax + ay * ay); eb[i] = sqrtf(bx * bx + by * by); ma += ea[i]; mb += eb[i];
    }
    ma /= MADEIRA_REMAP_SIG; mb /= MADEIRA_REMAP_SIG;
    float num = 0, da = 0, db = 0;
    for (int i = 0; i < MADEIRA_REMAP_SIG; i++) { float u = ea[i] - ma, v = eb[i] - mb; num += u * v; da += u * u; db += v * v; }
    return (da < 1e-9f || db < 1e-9f) ? 0 : num / sqrtf(da * db);
}

// On a frame's completion: score each anchor, pick the screen. Called with the lock held.
static void madeira_remap_choose(const float *live) {
    int best = -1; float bestScore = MADEIRA_REMAP_MATCH;
    for (int l = 0; l < g_remap.layoutCount; l++) {
        MadeiraRemapLayout *L = &g_remap.layouts[l];
        if (!L->anchored) continue;
        L->score = madeira_remap_signature_match(L->reference, live + l * MADEIRA_REMAP_SIG);
        if (L->score >= bestScore) { best = l; bestScore = L->score; }
    }
    int want = best >= 0 ? best : g_remap.fallback;
    if (want == g_remap.pending) g_remap.pendingRuns++; else { g_remap.pending = want; g_remap.pendingRuns = 1; }
    if (want != g_remap.active && g_remap.pendingRuns >= 2) {
        fprintf(stderr, "[screen-layout] screen %d -> %d (match %.2f)\n", g_remap.active, want, best >= 0 ? bestScore : 0);
        g_remap.active = want;
    }
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
    id<MTLFunction> sigFn = [lib newFunctionWithName:@"remap_signature"];
    id<MTLComputePipelineState> sig = sigFn ? [dev newComputePipelineStateWithFunction:sigFn error:&err] : nil;
    if (!sig) {
        fprintf(stderr, "[screen-layout] signature kernel failed: %s\n", err.localizedDescription.UTF8String ?: "?");
        g_remap.failed = 1;
        return NO;
    }
    g_remap.device = dev; g_remap.library = lib; g_remap.scratch = nil; g_remap.signature = sig;
    g_remap.pipelines = [NSMutableDictionary new];
    for (int i = 0; i < 3; i++)
        g_remap.signatures[i] = [dev newBufferWithLength:MADEIRA_REMAP_MAX_LAYOUTS * MADEIRA_REMAP_SIG * sizeof(float)
                                                 options:MTLResourceStorageModeShared];
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
                               double sx0, double sy0, double sx1, double sy1, const float p[4]) {
    float q[12] = { (float)(dx0 / W * 2 - 1), (float)(1 - dy0 / H * 2), (float)(dx1 / W * 2 - 1), (float)(1 - dy1 / H * 2),
                    (float)sx0, (float)sy0, (float)sx1, (float)sy1, p ? p[0] : 0, p ? p[1] : 0, p ? p[2] : 0, p ? p[3] : 0 };
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
    madeira_remap_quad(enc, W, H, 0, 0, W, H, 0, 0, W, H, NULL);   // 1:1, so Lanczos copies texels exactly
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
    double W = tex.width, H = tex.height;

    // Every 6th frame the anchors, read from the frame as the game drew it.
    if (g_remap.anchoredCount > 0 && g_remap.frames++ % 6 == 0) {
        id<MTLBuffer> buf = g_remap.signatures[g_remap.signatureNext++ % 3];
        float rects[MADEIRA_REMAP_MAX_LAYOUTS * 4];
        for (int l = 0; l < g_remap.layoutCount; l++) {
            const MadeiraRemapLayout *L = &g_remap.layouts[l];
            float *r = rects + l * 4;
            if (L->anchored) { r[0] = L->anchor[0] * W; r[1] = L->anchor[1] * H; r[2] = L->anchor[2] * W; r[3] = L->anchor[3] * H; }
            else { r[0] = 0; r[1] = 0; r[2] = 1; r[3] = 1; }   // one pixel, unused
        }
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:g_remap.signature];
        [ce setTexture:tex atIndex:0];
        [ce setBuffer:buf offset:0 atIndex:0];
        [ce setBytes:rects length:g_remap.layoutCount * 4 * sizeof(float) atIndex:1];
        [ce dispatchThreads:MTLSizeMake(48, 12, g_remap.layoutCount) threadsPerThreadgroup:MTLSizeMake(16, 4, 1)];
        [ce endEncoding];
        uint64_t generation = g_remap.generation;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (done.status != MTLCommandBufferStatusCompleted) return;
            pthread_mutex_lock(&g_remap.lock);
            if (generation == g_remap.generation) madeira_remap_choose(buf.contents);
            pthread_mutex_unlock(&g_remap.lock);
        }];
    }

    int active = g_remap.active;
    int first = active >= 0 ? g_remap.layouts[active].first : 0;
    int n = active >= 0 ? g_remap.layouts[active].count : 0;
    NSUInteger sx[MADEIRA_REMAP_MAX_ZONES], sy[MADEIRA_REMAP_MAX_ZONES], sw[MADEIRA_REMAP_MAX_ZONES], sh[MADEIRA_REMAP_MAX_ZONES];
    NSUInteger ex[MADEIRA_REMAP_MAX_ZONES], ey[MADEIRA_REMAP_MAX_ZONES], ew[MADEIRA_REMAP_MAX_ZONES], eh[MADEIRA_REMAP_MAX_ZONES];
    NSUInteger packW = 0, packH = 0;
    for (int i = 0; i < n; i++) {
        MadeiraRemapZone z = g_remap.zones[first + i];
        // source edges on the nearest pixel (a float 492/648 times 648 is 491.99997)
        sx[i] = (NSUInteger)MIN(lround(z.sx0 * W), (long)W - 1); sy[i] = (NSUInteger)MIN(lround(z.sy0 * H), (long)H - 1);
        sw[i] = (NSUInteger)MAX(MIN(lround(z.sx1 * W), (long)W) - (long)sx[i], 1);
        sh[i] = (NSUInteger)MAX(MIN(lround(z.sy1 * H), (long)H) - (long)sy[i], 1);
        // copied with the pixels around it (the blend's border), inside the frame
        ex[i] = sx[i] > 0 ? sx[i] - 1 : 0; ey[i] = sy[i] > 0 ? sy[i] - 1 : 0;
        ew[i] = MIN(sx[i] + sw[i] + 1, (NSUInteger)W) - ex[i]; eh[i] = MIN(sy[i] + sh[i] + 1, (NSUInteger)H) - ey[i];
        packW += ew[i]; packH = MAX(packH, eh[i]);
    }
    id<MTLRenderPipelineState> draw = n ? madeira_remap_pipeline(@"remap_fs", tex.pixelFormat) : nil;
    id<MTLRenderPipelineState> sharp = n ? madeira_remap_pipeline(@"remap_sharp_fs", tex.pixelFormat) : nil;
    id<MTLRenderPipelineState> fill = n ? madeira_remap_pipeline(@"remap_fill_fs", tex.pixelFormat) : nil;
    id<MTLRenderPipelineState> blend = n ? madeira_remap_pipeline(@"remap_blend_fs", tex.pixelFormat) : nil;
    if (n && draw && sharp && fill && blend && packW && packH) {
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
            [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(ex[i], ey[i], 0)
                       sourceSize:MTLSizeMake(ew[i], eh[i], 1) toTexture:scratch destinationSlice:0
                 destinationLevel:0 destinationOrigin:MTLOriginMake(x, 0, 0)];
            at[i] = x; x += ew[i];
        }
        [blit endEncoding];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex;
        rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setFragmentTexture:scratch atIndex:0];
        for (int i = 0; i < n; i++) {
            float hide = g_remap.zones[first + i].hide;
            if (hide <= 0) continue;
            // the source inside the scratch copy, and the ring of pixels around it
            double ix = at[i] + (sx[i] - ex[i]), iy = sy[i] - ey[i];
            float ring[4] = { (float)(sx[i] > ex[i] ? ix - 1 : ix), (float)(sy[i] > ey[i] ? iy - 1 : iy),
                              (float)(ex[i] + ew[i] > sx[i] + sw[i] ? ix + sw[i] : ix + sw[i] - 1),
                              (float)(ey[i] + eh[i] > sy[i] + sh[i] ? iy + sh[i] : iy + sh[i] - 1) };
            [enc setRenderPipelineState:hide >= 2 ? blend : fill];
            madeira_remap_quad(enc, W, H, sx[i], sy[i], sx[i] + sw[i], sy[i] + sh[i], ix, iy, ix + sw[i], iy + sh[i], ring);
        }
        for (int i = 0; i < n; i++) {
            MadeiraRemapZone z = g_remap.zones[first + i];
            double ix = at[i] + (sx[i] - ex[i]), iy = sy[i] - ey[i];
            float scale[4] = { (float)((z.dx1 - z.dx0) * W / sw[i]), (float)((z.dy1 - z.dy0) * H / sh[i]), 0, 0 };
            [enc setRenderPipelineState:z.sharp > 0 ? sharp : draw];
            madeira_remap_quad(enc, W, H, z.dx0 * W, z.dy0 * H, z.dx1 * W, z.dy1 * H, ix, iy, ix + sw[i], iy + sh[i], scale);
        }
        [enc endEncoding];
    }
    pthread_mutex_unlock(&g_remap.lock);
}
