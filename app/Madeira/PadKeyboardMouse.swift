import Foundation
import UIKit

/// A physical controller as keyboard and mouse, for games without controller
/// support (or with it switched off).
///
/// Steam does this for desktop players with Steam Input; Madeira Dock runs
/// Valve's client headless, so there is no Steam Input here, and nothing else
/// translates a pad for such a game. In this mode the pad is not published to
/// XInput at all: the game sees no controller, and every pad input is turned
/// into what the touch controls already produce, through the same posting
/// paths (winios_post_key, winios_pointer, HardwareInput.postRelative).
///
/// Bindings come from three places, the most specific winning:
/// - The game's own binds table (`LibraryEntry.controllerBinds`, edited in the
///   Session menu's Controller binds page and in Game details): one action per
///   controller input, stored with the game.
/// - A touch control of the active layout can name a controller input
///   (`TouchControl.padBinding`: "A", "LB", "RT", "D↑", ...; "LS" or "RS" for a
///   stick control). That input then does what the touch control does.
/// - Inputs neither of those bind take the built-in template below: WASD on
///   the left stick, mouse on the right stick, the triggers as the mouse
///   buttons, the D-pad as the arrow keys, Start as Escape, Select as Tab.
///
/// A stick can also move the mouse (either stick) or press four keys of the
/// player's choice (`.stickCustom`: the table's "LS↑" "LS→" "LS↓" "LS←" rows,
/// likewise for RS), say Q/E to turn a camera and Page Up/Down to zoom it.
/// The touch controller's sticks and buttons go through the same table.
///
/// The mode is a per-game choice (LibraryEntry.controllerMode, Game details and
/// the Session menu), off by default: a game with native controller support
/// keeps XInput, as before. MADEIRA_PAD_KBM=0 removes the choice.
struct PadBindings: Equatable {
    static let buttonNames = ["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "L3", "R3",
                              "Menu", "View", "D↑", "D↓", "D←", "D→"]
    static let stickNames = ["LS", "RS"]
    /// A custom key stick's directions, up/right/down/left: "LS↑" ... "RS←".
    static let directionArrows = ["↑", "→", "↓", "←"]
    static func directionNames(_ stick: String) -> [String] { directionArrows.map { stick + $0 } }
    /// What each stick may be set to; `.none` is nothing on LS and the mouse on RS.
    static func isStickChoice(_ a: ControlAction) -> Bool {
        a.stickKeys != nil || a == .stickMouse || a == .stickCustom
    }

    /// What each digital input does; the triggers count as digital here.
    var buttons: [String: ControlAction]
    /// The key stick the left stick drives (.joystickWASD/.joystickArrows), or
    /// .none when the right stick took the keys and the left one is unused.
    var leftStick: ControlAction
    /// The right stick moves the mouse (default) or drives a key stick.
    var rightStick: ControlAction
    /// What a `.stickCustom` stick's directions do, up/right/down/left, by stick.
    var stickDirections: [String: [ControlAction]] = Self.templateDirections
    /// Vertical speed of the right-stick mouse relative to its horizontal speed
    /// (1 = the same). Games scale pitch and yaw differently from a mouse, and a
    /// stick cannot be compensated by hand the way a wrist does.
    var mouseVertical: Double = 1.0

    /// The built-in template: the keyboard-and-mouse layout most PC games use.
    static let template = PadBindings(
        buttons: ["A": .key(0x20),            // Space
                  "B": .key(0x11),            // Ctrl
                  "X": .key(0x45),            // E
                  "Y": .key(0x52),            // R
                  "LB": .key(0x51),           // Q
                  "RB": .key(0x46),           // F
                  "LT": .mouseRight,
                  "RT": .mouseLeft,
                  "L3": .key(0x10),           // Shift
                  "R3": .key(0x43),           // C
                  "Menu": .key(0x1B),         // Escape
                  "View": .key(0x09),         // Tab
                  "D↑": .key(0x26), "D↓": .key(0x28), "D←": .key(0x25), "D→": .key(0x27)],
        leftStick: .joystickWASD,
        rightStick: .none)                    // .none on the right stick means: the mouse
    /// A stick just switched to custom keys starts with the keys it drove by default.
    static let templateDirections: [String: [ControlAction]] = [
        "LS": [.key(0x57), .key(0x44), .key(0x53), .key(0x41)],   // W D S A
        "RS": [.key(0x26), .key(0x27), .key(0x28), .key(0x25)],   // the arrow keys
    ]

    /// The template with the layout's own bindings on top, then the game's binds
    /// table on top of that. A binding replaces the template's entry for that
    /// input; a key stick bound to RS takes the right stick away from the mouse.
    /// In the table, `.none` on a button means "does nothing", on RS "the mouse",
    /// on LS "unused".
    static func build(controls: [TouchControl], binds: [String: ControlAction]? = nil, mouseVertical: Double? = nil) -> PadBindings {
        var b = template
        if let v = mouseVertical, v.isFinite { b.mouseVertical = min(max(v, 0.25), 2.0) }
        for c in controls {
            guard let name = c.padBinding else { continue }
            if c.action.stickKeys != nil {
                if name == "LS" { b.leftStick = c.action }
                else if name == "RS" { b.rightStick = c.action }
            } else if buttonNames.contains(name), !c.action.isPad, c.action != .none {
                b.buttons[name] = c.action
            }
        }
        for (name, action) in binds ?? [:] where !action.isPad {
            if name == "LS" { b.leftStick = isStickChoice(action) ? action : .none }
            else if name == "RS" { b.rightStick = isStickChoice(action) ? action : .none }
            else if isStickChoice(action) { continue }
            else if buttonNames.contains(name) { b.buttons[name] = action }
            else if let (stick, i) = direction(name) { b.stickDirections[stick]?[i] = action }
        }
        return b
    }

    /// "RS→" -> ("RS", 1); nil for any other name.
    static func direction(_ name: String) -> (String, Int)? {
        for stick in stickNames {
            if let i = directionNames(stick).firstIndex(of: name) { return (stick, i) }
        }
        return nil
    }

    /// What the template gives an input, for the binds page's "Default" rows.
    static func templateAction(_ name: String) -> ControlAction {
        switch name {
        case "LS": return template.leftStick
        case "RS": return template.rightStick
        default:
            if let (stick, i) = direction(name) { return templateDirections[stick]?[i] ?? .none }
            return template.buttons[name] ?? .none
        }
    }

    /// The binds page's row labels: XInput names in the table, Start/Select on screen.
    static func displayName(_ name: String) -> String {
        name == "Menu" ? "Start" : name == "View" ? "Select" : name
    }

    /// The four actions a stick presses, up/right/down/left; nil when it moves the mouse or does nothing.
    func stickActions(_ stick: String) -> [ControlAction]? {
        let mode = stick == "LS" ? leftStick : rightStick
        if mode == .stickCustom { return stickDirections[stick] }
        return mode.stickKeys?.map { .key($0) }
    }
    /// Whether a stick moves the mouse.
    func stickMovesMouse(_ stick: String) -> Bool {
        stick == "LS" ? leftStick == .stickMouse : (rightStick == .none || rightStick == .stickMouse)
    }
}

/// Turns pad samples into key and mouse events. Fed from GamepadInput's sampling
/// queue (250 Hz); every call runs on that queue, so the edge state needs no lock.
final class PadKeyboardMouse {
    static let shared = PadKeyboardMouse()

    /// XInput button masks, as GamepadInput publishes them.
    private static let masks: [(String, UInt16)] = [
        ("D↑", 0x0001), ("D↓", 0x0002), ("D←", 0x0004), ("D→", 0x0008),
        ("Menu", 0x0010), ("View", 0x0020), ("L3", 0x0040), ("R3", 0x0080),
        ("LB", 0x0100), ("RB", 0x0200), ("A", 0x1000), ("B", 0x2000), ("X", 0x4000), ("Y", 0x8000)
    ]
    private static let triggerThreshold: UInt8 = 128
    /// Stick deflection (0...1) below which no direction key is held.
    private static let stickDeadzone = 0.35

    private var held: Set<String> = []            // digital inputs currently down
    private var lastSample: UInt64 = 0             // mach time of the previous feed
    private var carry = MotionCarry()
    private var mouseMoving = false
    private var logged = 0

    /// One pad sample while the mode is on. `dt` comes from the sample clock.
    func feed(buttons: UInt16, lt: UInt8, rt: UInt8, lx: Int16, ly: Int16, rx: Int16, ry: Int16,
              bindings: PadBindings, focused: Bool) {
        let now = mach_absolute_time()
        let dt = lastSample == 0 ? 1.0 / 250.0 : Self.seconds(now - lastSample)
        lastSample = now

        var down: Set<String> = []
        for (name, mask) in Self.masks where buttons & mask != 0 { down.insert(name) }
        if lt >= Self.triggerThreshold { down.insert("LT") }
        if rt >= Self.triggerThreshold { down.insert("RT") }
        for name in held.subtracting(down) {
            if let a = pressedWith.removeValue(forKey: name) { act(a, down: false) }
        }
        for name in down.subtracting(held) {
            if let a = bindings.buttons[name] { pressedWith[name] = a; act(a, down: true) }
        }
        held = down

        let l = Self.unit(lx, ly), r = Self.unit(rx, ry)
        applyStick("LS", sector: Self.sector(l.x, l.y), actions: bindings.stickActions("LS"))
        applyStick("RS", sector: Self.sector(r.x, r.y), actions: bindings.stickActions("RS"))
        // The mouse follows the stick that moves it; with both, the one pushed further.
        var m = (x: 0.0, y: 0.0)
        for (stick, s) in [("LS", l), ("RS", r)] where bindings.stickMovesMouse(stick) {
            if s.x * s.x + s.y * s.y > m.x * m.x + m.y * m.y { m = s }
        }
        if focused, bindings.stickMovesMouse("LS") || bindings.stickMovesMouse("RS") {
            // Motion by the time since the last sample, unfloored: samples come from
            // the 4 ms timer and from every controller change, so StickVelocity.frame's
            // 1/240 s floor would make the cursor faster the more often the pad reports.
            let v = StickVelocity.deflect(m.x, m.y)
            let k = InputSettings.shared.sensRel * StickVelocity.fullRate * min(dt, 1.0 / 15.0)
            let f = (dx: v.x * k, dy: -v.y * k)
            if f.dx != 0 || f.dy != 0 {
                let d = carry.add(f.dx, f.dy * bindings.mouseVertical, gain: 1)
                if d.dx != 0 || d.dy != 0 {
                    if !mouseMoving {
                        mouseMoving = true
                        DispatchQueue.main.async { HardwareInput.shared.stickMoved() }
                    }
                    HardwareInput.shared.postRelative(d.dx, d.dy)
                }
            } else if mouseMoving {
                mouseMoving = false
                carry.reset()
            }
        }
    }

    /// Whether a key or mouse button is down, or the mouse is moving.
    var holding: Bool { !pressedWith.isEmpty || mouseMoving }

    /// Release everything this driver holds: the mode went off, the app
    /// resigned active, the session ended, the library took the pad, or the
    /// controller disconnected.
    func releaseAll(_ why: String) {
        for (_, a) in pressedWith { act(a, down: false) }
        pressedWith.removeAll()
        held.removeAll()
        lastSample = 0
        carry.reset()
        mouseMoving = false
        if logged < 32 { logged += 1; fputs("[pad-kbm] released (\(why))\n", stderr) }
    }

    /// Each input is released through the action it was pressed with, so a layout
    /// edit during a hold cannot leave a key down. Keyed by input name: buttons
    /// ("A") and held stick directions ("LS↑").
    private var pressedWith: [String: ControlAction] = [:]
    private func act(_ action: ControlAction, down: Bool) {
        switch action {
        case .key(let vk):
            winios_post_key(vk, down ? 1 : 0)
        case .mouseLeft:
            winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0)   // LEFTDOWN / LEFTUP
        case .mouseRight:
            winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0)   // RIGHTDOWN / RIGHTUP
        case .mouseMiddle:
            winios_pointer(0, 0, down ? 0x0020 : 0x0040, 0)   // MIDDLEDOWN / MIDDLEUP
        case .keyboardToggle:
            if down { DispatchQueue.main.async { MetalBackedView.toggleKeyboard() } }
        case .none, .joystickWASD, .joystickArrows, .stickMouse, .stickCustom, .pad:
            break                                              // sticks are handled by sector; pad actions are XInput's
        }
    }

    // ---- stick arithmetic, the same sectors as the touch key sticks ----

    private static func unit(_ x: Int16, _ y: Int16) -> (x: Double, y: Double) {
        (Double(x) / 32767.0, Double(y) / 32767.0)
    }
    /// 0 = up, clockwise in 45° steps; -1 inside the dead zone.
    static func sector(_ x: Double, _ y: Double) -> Int {
        guard (x * x + y * y).squareRoot() >= stickDeadzone else { return -1 }
        var a = atan2(x, y) * 180 / .pi            // 0° is up, 90° is right
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }
    /// The directions (0 up, 1 right, 2 down, 3 left) a sector holds: one, or two on a diagonal.
    static func sectorDirections(_ d: Int) -> [Int] {
        switch d {
        case 0: return [0]
        case 1: return [0, 1]
        case 2: return [1]
        case 3: return [2, 1]
        case 4: return [2]
        case 5: return [2, 3]
        case 6: return [3]
        case 7: return [0, 3]
        default: return []
        }
    }
    /// Release what is no longer held and press what newly is, so a held
    /// direction does not stutter while the thumb wanders inside one sector.
    /// `actions` nil (the stick moves the mouse or does nothing) holds none.
    private func applyStick(_ stick: String, sector: Int, actions: [ControlAction]?) {
        let names = PadBindings.directionNames(stick)
        let new = Set((actions == nil ? [] : Self.sectorDirections(sector)).map { names[$0] })
        let old = Set(names.filter { pressedWith[$0] != nil })
        for name in old.subtracting(new) { if let a = pressedWith.removeValue(forKey: name) { act(a, down: false) } }
        for name in new.subtracting(old) {
            if let i = names.firstIndex(of: name), let a = actions?[i] { pressedWith[name] = a; act(a, down: true) }
        }
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
    private static func seconds(_ ticks: UInt64) -> Double { Double(ticks) * timebase }
}
