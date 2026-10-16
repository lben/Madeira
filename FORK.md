# lben/Madeira — what this fork adds

A personal fork of [willfaust/Madeira](https://github.com/willfaust/Madeira), used on an iPhone 16 Pro
(iOS 26) with a free Apple developer account (no extended virtual addressing). Everything here is
built by the fork's CI (`.github/workflows/build-ios.yml`) and signed locally.

The work is in three layers:

1. **General improvements, meant for Madeira itself** (each is a separate branch, proposed upstream):
   - **Relaunch between games** (`relaunch-between-games`): a second Wine session relaunches Madeira
     through a "Madeira Reopen" shortcut and starts the pending game.
   - **Steam Cloud retry** before play when the Steam connection is still coming up.
   - **Screen layouts** (`screen-layouts-m*`): per-game copies of parts of the frame (HUD text, menus)
     enlarged elsewhere on screen, with screens recognised by an anchor; Find text; see-through copies.
   - **JIT over cellular** (`jit-cellular-online`): the Madeira JIT shortcut turns cellular data off for
     JIT; the Dock now waits for the network to come back and logs on online.
   - **Controller as keyboard and mouse** (`console-controls`, `mapping-text`, `controls-hybrid`):
     custom key sticks (one key per direction), either stick as mouse, middle click, the on-screen
     controller through the same binds, taps that hold their click 70 ms, a mapping as text with a
     prompt so any AI can write a game's mapping, backup/restore, a long press for the touch mouse.
   - **Giant reservations** (`controls-hybrid`): a failed ≥1 GB reserve tries the free holes of the
     VM map, lowest first (Gears Tactics).
   - **arm64ec farm** (`games-fixes`): `wer.dll`, which Gears Tactics needs to load.
   - **DXMT** (`lben/dxmt`): accept a geometry shader's `vGSInstanceID` declaration (Frostpunk; branch
     `madeira-remap-hook`, which the `dxmt` submodule follows); opt-in `d3d11.downscaleMip1` (large
     single-level textures stored at half size; branch `downscale-mip1`, not yet in the app's
     d3d11.dll, so Frostpunk uses a d3d11.dll built from it in the game's folder).
2. **Fork-specific**: signing scripts and notes live outside the repo; nothing in the app depends on them.
3. **Per game**: `games/` — one file per game with its Madeira settings (config lines, launch options,
   controller mapping as text to paste) and what works.
