# Frostpunk (Steam 323190)

**Status:** plays, including loading saves. Direct3D 11 through DXMT.

## Why the settings
Loading a save used to be killed by iOS at its 6144 MB memory limit. About 1.5 GB of the game's
textures have a single mip level (UI art, BC3 atlases, BGRA8 illustrations), so a mip clamp cannot
shrink them. `d3d11.downscaleMip1=1024` stores those (≥1024 px) at half width and height; together
with `d3d11.mipClampBC=1` the save-load peak went from 6136 MB (killed) to ~5.46 GB.

## This game's config
```
dxmt = d3d11.mipClampBC=1;d3d11.downscaleMip1=1024
```

`d3d11.downscaleMip1` is not yet in the app's d3d11.dll: build DXMT from lben/dxmt branch
`downscale-mip1` and put that d3d11.dll next to Frostpunk.exe (Wine looks in the game's folder first).

## Controls
Frostpunk on PC has no controller support. With Controller = Keyboard and mouse, a console-style
mapping (camera: WASD on the D-pad, turn Q/E and zoom Page Up/Page Down on the right stick; the
left stick is the pointer). Paste into Controller binds › Mapping as text:

```
# Madeira controller mapping for Frostpunk
mode: keyboard and mouse
LS: mouse
RS: keys
RS up: Page Up
RS right: E
RS down: Page Down
RS left: Q
A: left click
B: right click
X: Space
Y: O
LB: 2
RB: 3
LT: L
RT: T
L3: 1
R3: middle click
Start: Escape
Select: Tab
D-pad up: W
D-pad down: S
D-pad left: A
D-pad right: D
```

Notes: menus are mouse-driven (pick a save, then LOAD); a finger held one second on the screen
turns the touch mouse on while the on-screen controller is shown.
