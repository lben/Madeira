# Gears Tactics (Steam 1184050)

**Status:** work in progress. Direct3D 12 by default (Madeira's madeira-d3d12); the binary also has
Unreal's D3D11 renderer (`-dx11` launch option).

- Needs `wer.dll` (in the fork's arm64ec farm); without it the game stops at load with c0000135.
- Unreal reserves ten pools, 40 GB of the 63 GB address map a free developer account gets (no
  extended virtual addressing). Whether the tenth (1 GB) fits depends on where the seventh lands:
  one run in seven got past them. The fork now places a failed giant reservation in the lowest free
  hole of the map.
- In the run that got past them, the game drew its first frames under D3D12 and then crashed on a
  null object in its own code (the code is encrypted on disk, so it is not yet known which one).
