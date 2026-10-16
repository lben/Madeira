#!/usr/bin/env python3
"""A controller as keyboard and mouse: compile the production driver on a POSIX host.

app/Madeira/PadKeyboardMouse.swift (the bindings and the driver), with
ControlAction/TouchControl from ContentView.swift and the pure section of
HardwareInput.swift, is compiled with swiftc against stubs that record what it
posts, and fed pad samples: the template, a custom key stick (one key per
direction, diagonals and release), the left stick as the mouse, middle click,
binds tables saved before the stick choices existed, and releaseAll.

Needs python3 and swiftc (SWIFTC to override). No iOS SDK, device or controller.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
content = (app / 'ContentView.swift').read_text()
actions = content[content.index('enum ControlAction: Codable'):content.index('final class TouchControlsModel')]
hardware = (app / 'HardwareInput.swift').read_text()
pure = hardware.split('// MARK: - Pure input mapping', 1)[1].split('// MARK: - Device glue', 1)[0]
driver = (app / 'PadKeyboardMouse.swift').read_text().replace('import UIKit\n', '')

stubs = r'''
var posted: [String] = []
func winios_post_key(_ vk: Int32, _ down: Int32) { posted.append("key \(String(format: "%02X", vk)) \(down == 1 ? "down" : "up")") }
func winios_pointer(_ x: Int32, _ y: Int32, _ flags: UInt32, _ data: UInt32) { posted.append("ptr \(String(format: "%04X", flags))") }
final class HardwareInput {
    static let shared = HardwareInput()
    var moved = (dx: Int32(0), dy: Int32(0))
    func postRelative(_ dx: Int32, _ dy: Int32) { moved.dx += dx; moved.dy += dy }
    func stickMoved() {}
}
final class InputSettings { static let shared = InputSettings(); var sensRel = 2.0 }
enum MetalBackedView { static func toggleKeyboard() {} }
'''

tests = r'''
let pad = PadKeyboardMouse.shared
func feed(_ b: PadBindings, buttons: UInt16 = 0, lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0) {
    pad.feed(buttons: buttons, lt: 0, rt: 0, lx: lx, ly: ly, rx: rx, ry: ry, bindings: b, focused: true)
}
func take() -> [String] { defer { posted = [] }; return posted }

// The template: the left stick is WASD, the right stick the mouse, A Space.
let template = PadBindings.build(controls: [])
feed(template, lx: -32767)
assert(take() == ["key 41 down"], "left stick left = A")
feed(template)
assert(take() == ["key 41 up"])
feed(template, buttons: 0x1000)
assert(take() == ["key 20 down"])
feed(template)
assert(take() == ["key 20 up"])
assert(template.stickMovesMouse("RS") && !template.stickMovesMouse("LS"))

// A custom right stick: Q/E to turn, Page Up/Down to zoom; the left stick moves the mouse.
let frostpunkTable: [String: ControlAction] = [
    "LS": .stickMouse, "RS": .stickCustom,
    "RS←": .key(0x51), "RS→": .key(0x45), "RS↑": .key(0x21), "RS↓": .key(0x22),
    "A": .mouseLeft, "B": .mouseRight, "R3": .mouseMiddle]
let frostpunk = PadBindings.build(controls: [], binds: frostpunkTable)
assert(frostpunk.stickActions("RS") == [.key(0x21), .key(0x45), .key(0x22), .key(0x51)])
assert(frostpunk.stickActions("LS") == nil && frostpunk.stickMovesMouse("LS") && !frostpunk.stickMovesMouse("RS"))
feed(frostpunk, rx: 32767)
assert(take() == ["key 45 down"], "right = E")
feed(frostpunk, rx: 23170, ry: 23170)
assert(take() == ["key 21 down"], "up-right adds Page Up and keeps E held")
feed(frostpunk, rx: -32767)
assert(Set(take()) == ["key 45 up", "key 21 up", "key 51 down"], "left: E and Page Up released, Q pressed")
feed(frostpunk)
assert(take() == ["key 51 up"])
HardwareInput.shared.moved = (0, 0)
for _ in 0..<25 { feed(frostpunk, lx: 32767); usleep(4000) }   // the driver times motion by the sample clock
assert(HardwareInput.shared.moved.dx > 0 && HardwareInput.shared.moved.dy == 0, "left stick moves the mouse right")
assert(take().isEmpty, "a mouse stick presses no keys")
feed(frostpunk)
feed(frostpunk, buttons: 0x0080)
assert(take() == ["ptr 0020"], "R3 = middle button down")
feed(frostpunk)
assert(take() == ["ptr 0040"])

// Unset custom directions start from the stick's own default keys.
let partial = PadBindings.build(controls: [], binds: ["LS": .stickCustom, "LS↑": .key(0x20)])
assert(partial.stickActions("LS") == [.key(0x20), .key(0x44), .key(0x53), .key(0x41)])

// Tables saved before the stick choices: RS .none is the mouse, LS .none nothing,
// and a stick choice on a button row is ignored.
let old = try! JSONDecoder().decode([String: ControlAction].self,
    from: #"{"RS":{"none":{}},"LS":{"joystickArrows":{}},"X":{"key":{"_0":81}}}"#.data(using: .utf8)!)
let legacy = PadBindings.build(controls: [], binds: old.merging(["Y": .stickCustom]) { a, _ in a })
assert(legacy.stickMovesMouse("RS") && legacy.leftStick == .joystickArrows && legacy.buttons["X"] == .key(0x51))
assert(legacy.buttons["Y"] == .key(0x52), "a stick choice cannot land on a button")
let none = PadBindings.build(controls: [], binds: ["LS": .none])
assert(none.stickActions("LS") == nil && !none.stickMovesMouse("LS"))

// The new choices survive a save.
let saved = try! JSONEncoder().encode(["LS": ControlAction.stickMouse, "RS": .stickCustom, "B": .mouseMiddle])
assert(try! JSONDecoder().decode([String: ControlAction].self, from: saved) == ["LS": .stickMouse, "RS": .stickCustom, "B": .mouseMiddle])

// releaseAll lets go of held directions and buttons.
feed(frostpunk, buttons: 0x1000, rx: 32767)
assert(Set(take()) == ["ptr 0002", "key 45 down"])
pad.releaseAll("test")
assert(Set(take()) == ["ptr 0004", "key 45 up"])
assert(!pad.holding)
// Mapping as text: what Copy mapping writes reads back to the same bindings.
let fpText = PadMappingText.text(PadBindings.build(controls: [], binds: frostpunkTable, mouseVertical: 0.8), game: "Frostpunk")
assert(fpText.contains("RS: keys\nRS up: Page Up") && fpText.contains("R3: middle click") && fpText.contains("vertical speed: 80%"))
let readBack = PadMappingText.parse(fpText)
assert(readBack.problems.isEmpty, "\(readBack.problems)")
assert(PadBindings.build(controls: [], binds: readBack.binds, mouseVertical: readBack.mouseVertical)
       == PadBindings.build(controls: [], binds: frostpunkTable, mouseVertical: 0.8), "text round trip")

// An AI's whole answer pasted: only the code block counts; other spellings and
// trailing explanations are read, and unreadable lines are reported, not applied.
let answer = """
Here is the mapping:

```
# Madeira controller mapping for Frostpunk
mode: keyboard and mouse
Left stick: mouse
Right Stick: Keys
RS left: Q   (turn left)
RS right: e
right stick up: PgUp
RS down: page down // zoom out
A: Left Click
B: right click — cancel
X: Spacebar (pause)
LB: 2
Guide: Escape
LT: wheel up
RS: nothing
vertical speed: 120%
```
Enjoy!
"""
let pasted = PadMappingText.parse(answer)
assert(pasted.binds == ["LS": .stickMouse, "RS": .stickCustom, "RS←": .key(0x51), "RS→": .key(0x45), "RS↑": .key(0x21),
                        "RS↓": .key(0x22), "A": .mouseLeft, "B": .mouseRight, "X": .key(0x20), "LB": .key(0x32)], "\(pasted.binds)")
assert(pasted.mouseVertical == 1.2)
assert(pasted.problems.count == 3 && pasted.problems[0].contains("Guide") && pasted.problems[1].contains("wheel up")
       && pasted.problems[2].contains("nothing"), "\(pasted.problems)")
assert(PadMappingText.parse("hello").binds.isEmpty)

// The prompt carries the game, the player's request, the format and the mapping now.
let prompt = PadMappingText.prompt(game: "Frostpunk", appID: 323190, request: "like the console edition", current: fpText)
assert(prompt.contains("\"Frostpunk\" (Steam app 323190)") && prompt.contains("What I want: like the console edition"))
assert(prompt.contains("RS up: Page Up") && prompt.contains("Key names: A–Z") && prompt.hasSuffix("vertical speed: 80%\n```"))
assert(PadMappingText.prompt(game: "X", appID: nil, request: " ", current: "").contains("[WRITE HERE"))
print("PASS: template, custom key stick with diagonals, left stick mouse, middle click, legacy tables, releaseAll, mapping text and AI prompt")
'''

with tempfile.TemporaryDirectory(prefix='madeira-pad-kbm-') as tmp:
    src, exe = Path(tmp) / 'main.swift', Path(tmp) / 'check'
    src.write_text('import Foundation\n' + stubs + actions + pure + driver + tests)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
