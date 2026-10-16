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
    /// What the left stick does: a key stick (.joystickWASD/.joystickArrows/
    /// .stickCustom), .stickMouse, or .none (nothing).
    var leftStick: ControlAction
    /// The right stick moves the mouse (default) or drives a key stick.
    var rightStick: ControlAction
    /// What a `.stickCustom` stick's directions do, up/right/down/left, by stick.
    var stickDirections: [String: [ControlAction]] = Self.templateDirections
    /// Vertical speed of the stick mouse relative to its horizontal speed
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
        default:   return template.buttons[name] ?? .none
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

/// A game's controller binds as text, to share a mapping or have an AI write one
/// (Controller binds › Copy prompt for an AI / Paste mapping / Copy mapping).
/// One `input: action` per line; `#` starts a comment; anything after the action
/// in parentheses is ignored, so an answer's explanations can stay in. Pasting
/// replaces the game's whole table: inputs it does not name are at their default.
enum PadMappingText {
    /// Inputs in the order the text lists them, with the table's name for each.
    static let inputs: [(text: String, name: String)] = [
        ("LS", "LS"), ("RS", "RS"),
        ("A", "A"), ("B", "B"), ("X", "X"), ("Y", "Y"),
        ("LB", "LB"), ("RB", "RB"), ("LT", "LT"), ("RT", "RT"),
        ("L3", "L3"), ("R3", "R3"), ("Start", "Menu"), ("Select", "View"),
        ("D-pad up", "D↑"), ("D-pad down", "D↓"), ("D-pad left", "D←"), ("D-pad right", "D→"),
    ]
    static let directionWords = ["up", "right", "down", "left"]

    /// Key names, as the text writes them.
    static let keys: [(String, Int32)] = {
        var k: [(String, Int32)] = []
        for vk in 0x41...0x5A { k.append((String(UnicodeScalar(UInt8(vk))), Int32(vk))) }
        for vk in 0x30...0x39 { k.append((String(UnicodeScalar(UInt8(vk))), Int32(vk))) }
        for i in 0..<12 { k.append(("F\(i + 1)", Int32(0x70 + i))) }
        k += [("Escape", 0x1B), ("Tab", 0x09), ("Shift", 0x10), ("Ctrl", 0x11), ("Alt", 0x12),
              ("Space", 0x20), ("Enter", 0x0D), ("Backspace", 0x08), ("Caps Lock", 0x14),
              ("Up", 0x26), ("Down", 0x28), ("Left", 0x25), ("Right", 0x27),
              ("Insert", 0x2D), ("Delete", 0x2E), ("Home", 0x24), ("End", 0x23),
              ("Page Up", 0x21), ("Page Down", 0x22),
              ("-", 0xBD), ("=", 0xBB), ("[", 0xDB), ("]", 0xDD), ("\\", 0xDC), (";", 0xBA),
              ("'", 0xDE), (",", 0xBC), (".", 0xBE), ("/", 0xBF), ("`", 0xC0)]
        for i in 0...9 { k.append(("Numpad \(i)", Int32(0x60 + i))) }
        k += [("Numpad *", 0x6A), ("Numpad +", 0x6B), ("Numpad -", 0x6D), ("Numpad .", 0x6E), ("Numpad /", 0x6F)]
        return k
    }()
    /// Other spellings an answer may use, after `norm`.
    private static let keyAliases: [String: Int32] = [
        "esc": 0x1B, "control": 0x11, "leftctrl": 0x11, "lctrl": 0x11, "leftshift": 0x10, "lshift": 0x10,
        "leftalt": 0x12, "lalt": 0x12, "return": 0x0D, "spacebar": 0x20, "pgup": 0x21,
        "pgdn": 0x22, "pgdown": 0x22, "uparrow": 0x26, "arrowup": 0x26,
        "downarrow": 0x28, "arrowdown": 0x28, "leftarrow": 0x25, "arrowleft": 0x25,
        "rightarrow": 0x27, "arrowright": 0x27, "del": 0x2E, "ins": 0x2D,
        "minus": 0xBD, "equals": 0xBB, "comma": 0xBC, "period": 0xBE, "slash": 0xBF,
        "backslash": 0xDC, "semicolon": 0xBA, "apostrophe": 0xDE, "grave": 0xC0, "backtick": 0xC0, "tilde": 0xC0,
    ]
    private static let inputAliases: [String: String] = [
        "leftbumper": "LB", "rightbumper": "RB", "lefttrigger": "LT", "righttrigger": "RT",
        "l1": "LB", "r1": "RB", "l2": "LT", "r2": "RT",
        "leftstickclick": "L3", "rightstickclick": "R3", "lsclick": "L3", "rsclick": "R3",
        "options": "Menu", "back": "View", "share": "View",
        "leftstick": "LS", "rightstick": "RS",
    ]

    /// Lower case, without spaces, hyphens or underscores: "D-pad Up" -> "dpadup".
    static func norm(_ s: String) -> String {
        s.lowercased().filter { !" -_".contains($0) }
    }
    /// For key names: as `norm` but keeping hyphens, so "-" and "Numpad -" stay
    /// themselves instead of becoming "" and "numpad".
    static func keyNorm(_ s: String) -> String {
        s.lowercased().filter { !" _".contains($0) }
    }

    static func keyName(_ vk: Int32) -> String? { keys.first { $0.1 == vk }?.0 }

    /// The table's name for an input written in the text; nil if unknown.
    static func input(_ text: String) -> String? {
        let n = norm(text)
        for (t, name) in inputs where norm(t) == n || norm(name) == n { return name }
        if let name = inputAliases[n] { return name }
        for stick in ["LS", "RS"] {
            let long = stick == "LS" ? "leftstick" : "rightstick"
            for (i, word) in directionWords.enumerated()
            where n == stick.lowercased() + word || n == long + word || n == norm(PadBindings.directionNames(stick)[i]) {
                return PadBindings.directionNames(stick)[i]
            }
        }
        for (i, word) in directionWords.enumerated() where n == "d" + word || n == "dpad" + word {
            return ["D↑", "D→", "D↓", "D←"][i]
        }
        return nil
    }

    /// What a stick row's text means; nil if it is not a stick choice.
    static func stickAction(_ text: String, stick: String) -> ControlAction? {
        switch norm(text) {
        case "mouse", "pointer", "cursor": return stick == "RS" ? ControlAction.none : .stickMouse
        case "wasd": return .joystickWASD
        case "arrows", "arrowkeys": return .joystickArrows
        case "keys", "custom", "customkeys": return .stickCustom
        case "nothing", "none": return stick == "LS" ? ControlAction.none : nil
        default: return nil
        }
    }
    /// What a button or stick direction row's text means; nil if unknown.
    static func buttonAction(_ text: String) -> ControlAction? {
        let n = norm(text), k = keyNorm(text)
        guard !k.isEmpty else { return nil }   // "Y:" with nothing after it is not the minus key
        switch n {
        case "leftclick", "click", "lmb", "leftmouse", "mouseleft": return .mouseLeft
        case "rightclick", "rmb", "rightmouse", "mouseright": return .mouseRight
        case "middleclick", "mmb", "middlemouse", "mousemiddle", "wheelclick": return .mouseMiddle
        case "nothing", "none", "unbound": return ControlAction.none
        case "showkeyboard", "keyboard": return .keyboardToggle
        default: break
        }
        if let key = keys.first(where: { keyNorm($0.0) == k }) { return .key(key.1) }
        guard !n.isEmpty else { return nil }
        // Hyphens inside a name ("Page-Up", "Numpad-5"), for every name that has no "-" of its own.
        if let key = keys.first(where: { !$0.0.contains("-") && norm($0.0) == n }) { return .key(key.1) }
        if let vk = keyAliases[n] { return .key(vk) }
        return nil
    }

    static func describe(_ a: ControlAction) -> String {
        switch a {
        case .none:           return "nothing"
        case .mouseLeft:      return "left click"
        case .mouseRight:     return "right click"
        case .mouseMiddle:    return "middle click"
        case .keyboardToggle: return "show keyboard"
        case .joystickWASD:   return "WASD"
        case .joystickArrows: return "arrows"
        case .stickMouse:     return "mouse"
        case .stickCustom:    return "keys"
        case .key(let vk):    return keyName(vk) ?? String(format: "key %02X", vk)
        case .pad(let n):     return n
        }
    }

    /// The whole mapping in effect: every input, the stick keys of a custom stick, the vertical speed.
    static func text(_ b: PadBindings, game: String) -> String {
        var lines = ["# Madeira controller mapping\(game.isEmpty ? "" : " for \(game)")", "mode: keyboard and mouse"]
        for (t, name) in inputs {
            if name == "LS" || name == "RS" {
                let mode = name == "LS" ? b.leftStick : b.rightStick
                lines.append("\(t): \(b.stickMovesMouse(name) ? "mouse" : describe(mode))")
                if mode == .stickCustom, let d = b.stickDirections[name] {
                    for (i, word) in directionWords.enumerated() { lines.append("\(t) \(word): \(describe(d[i]))") }
                }
            } else {
                lines.append("\(t): \(describe(b.buttons[name] ?? .none))")
            }
        }
        if abs(b.mouseVertical - 1) > 0.001 { lines.append("vertical speed: \(Int((b.mouseVertical * 100).rounded()))%") }
        return lines.joined(separator: "\n")
    }

    struct Parsed {
        var binds: [String: ControlAction] = [:]
        var mouseVertical: Double?
        var problems: [String] = []
    }
    static func parse(_ text: String) -> Parsed {
        var p = Parsed()
        // A whole answer pasted: only its code blocks are the mapping.
        let fenced = text.contains("```")
        var inside = false
        for (number, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inside.toggle(); continue }
            if fenced && !inside { continue }
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]).trimmingCharacters(in: .whitespaces) }
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else {
                p.problems.append("line \(number + 1): no \"input: action\" in \"\(raw.trimmingCharacters(in: .whitespaces))\""); continue
            }
            let left = line[..<colon].trimmingCharacters(in: .whitespaces)
            var right = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // An explanation after the action: "Space (pause)", "Q // turn left".
            for cut in [" (", " //", " —", " – "] { if let r = right.range(of: cut) { right = String(right[..<r.lowerBound]) } }
            right = right.trimmingCharacters(in: .whitespaces)
            switch norm(left) {
            case "mode", "game": continue
            case "verticalspeed":
                if let v = Double(right.filter { $0.isNumber || $0 == "." }), v > 0 {
                    p.mouseVertical = min(max(right.contains("%") || v > 3 ? v / 100 : v, 0.25), 1.5)
                } else { p.problems.append("line \(number + 1): vertical speed \"\(right)\" is not a percentage") }
                continue
            default: break
            }
            guard let name = input(left) else { p.problems.append("line \(number + 1): unknown input \"\(left)\""); continue }
            let action = name == "LS" || name == "RS" ? stickAction(right, stick: name) : buttonAction(right)
            guard let action else { p.problems.append("line \(number + 1): \(left) cannot be \"\(right)\""); continue }
            p.binds[name] = action
        }
        return p
    }

    /// A prompt for an AI chat: the game, how Madeira maps a controller, the
    /// format to answer in and the mapping the game has now.
    static func prompt(game: String, appID: Int?, request: String, current: String) -> String {
        let id = appID.map { " (Steam app \($0))" } ?? ""
        let want = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let wish = want.isEmpty ? "[WRITE HERE, for example \"like the console edition\", \"like the most popular Steam Deck community layout\", \"camera rotation on the right stick\"]" : want
        let keyList = "A–Z, 0–9, F1–F12, Escape, Tab, Shift, Ctrl, Alt, Space, Enter, Backspace, Caps Lock, Up, Down, Left, Right, Insert, Delete, Home, End, Page Up, Page Down, - = [ ] \\ ; ' , . / `, Numpad 0–9, Numpad *, Numpad +, Numpad -, Numpad ., Numpad /"
        return """
        I play the Windows PC game "\(game)"\(id) on an iPhone with Madeira, an app that runs Windows games. Madeira's "Keyboard and mouse" controller mode turns a game controller (a physical one, or Madeira's on-screen touch controller) into the game's keyboard keys and mouse input, for games without controller support or where it is worse.

        Please write a controller mapping for this game. What I want: \(wish)

        Before answering, research:
        1. The game's PC keyboard and mouse controls (in-game controls list, official manual, wikis, guides).
        2. The console edition's controller layout, if the game was released on consoles.
        3. The most popular Steam Input / Steam Deck community layouts for the game.
        Use only actions the PC version has, through its PC keys.

        How Madeira maps a controller:
        - Inputs (Xbox names): A, B, X, Y, LB, RB, LT, RT (triggers act as buttons), L3, R3 (stick clicks), Start, Select, D-pad up/down/left/right, and the sticks LS and RS.
        - A button, trigger or D-pad direction holds one action while pressed: a key, "left click", "right click", "middle click", "show keyboard" (the iPhone keyboard) or "nothing". One input = one key; there are no combinations, macros or modifiers.
        - A stick is "mouse" (moves the pointer), "WASD", "arrows" (the arrow keys), "keys" (four actions of your choice, given as "LS up", "LS down", "LS left", "LS right", or the same for RS) or "nothing" (LS only). A diagonal holds both of its directions; keys are held while the stick is pushed past about a third of its range, with no analogue pressure.
        - There is no mouse wheel action. If the game zooms only with the wheel, prefer a zoom key, or leave zoom to the touch screen.
        - The screen also works as a trackpad (drag moves the pointer, tap = left click, two-finger tap = right click, two-finger drag = scroll wheel), so the controller need not cover everything.
        - Key names: \(keyList).

        Answer with a short table explaining each choice, then the mapping as ONE code block in exactly this format, one "input: action" per line (# starts a comment):

        ```
        # Madeira controller mapping for \(game)
        mode: keyboard and mouse
        LS: mouse
        RS: keys
        RS up: Page Up
        RS down: Page Down
        RS left: Q
        RS right: E
        A: left click
        B: right click
        D-pad up: W
        Start: Escape
        ```

        Inputs you leave out keep Madeira's defaults (left stick WASD, right stick mouse, RT left click, LT right click, D-pad arrows, A Space, B Ctrl, X E, Y R, LB Q, RB F, L3 Shift, R3 C, Start Escape, Select Tab), so list every input you want to change.

        The game's mapping now:
        ```
        \(current)
        ```
        """
    }
}
