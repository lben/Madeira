// IOSDisplayShim.h — bridges Wine/DXMT's expected macdrv_* driver API to
// an iOS CAMetalLayer handed in from Swift.
//
// DXMT's winemetal unix side calls dlsym(RTLD_DEFAULT, "macdrv_functions"),
// and if that's present, uses get_win_data → client_cocoa_view →
// macdrv_view_create_metal_view → macdrv_view_get_metal_layer to obtain a
// CAMetalLayer from an HWND. On iOS there's one window (the device screen),
// so the shim resolves every HWND to the single Swift-owned CAMetalLayer.

#ifndef IOS_DISPLAY_SHIM_H
#define IOS_DISPLAY_SHIM_H

#ifdef __OBJC__
#import <QuartzCore/CAMetalLayer.h>
// Register the CAMetalLayer that DXMT-rendered content should go into.
// Must be called before the first D3D11 swapchain is created.
void madeira_display_set_layer(CAMetalLayer *layer);

// Posted (on the main queue) when the guest's virtual monitor changes size.
extern NSString * const MadeiraDisplayModeChangedNotification;

// Screen layouts (the last step on a game frame, see IOSDisplayShim.m).
// `count` zones (at most 32; 0 clears them), 11 floats each in the frame's
// normalised coordinates (origin top-left): source x0 y0 x1 y1, destination x0 y0
// x1 y1, hide (0 no, 1 black, 2 blended from the pixels around it), sharp (1 = square
// pixels, for pixel art; 0 = smooth Lanczos-3), sharpen (0 none, up to 3). anchors[i*4..]:
// zone i's anchor rect, x0 y0 x1 y1, or -1s for none (always drawn); signatures[i*576..]:
// the anchor's 48x12 luma reference (row-major, 0..1, box averages as the hook's
// remap_signature kernel computes them).
void madeira_remap_set_zones(int count, const float *zones, const float *anchors, const float *signatures);
// Whether zone i is drawn now (its anchor matched, or it has none).
int madeira_remap_zone_drawn(int zone);
// Edge NCC of two 48x12 signatures (1 = the same picture).
float madeira_remap_signature_match(const float *a, const float *b);
// The next game frame as the game drew it (before any zone), on the main queue;
// NULL when it could not be read or a newer request replaced this one.
typedef void (^MadeiraFrameCapture)(CGImageRef image);
void madeira_remap_capture(MadeiraFrameCapture done);
#endif

// The guest's virtual-monitor size in guest pixels, for the front end's
// layout and touch mapping. Seeded from MADEIRA_SCREEN_W/H (the session
// default win32u uses, 1024x768 when unset); winios_display_mode_changed()
// lets a win32u that supports mode changes publish a new size.
void winios_screen_size(int *w, int *h);
void winios_display_mode_changed(int w, int h);

#endif
