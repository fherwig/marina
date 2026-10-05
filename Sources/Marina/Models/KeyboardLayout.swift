import AppKit
import Carbon

/// Where the terminal shortcut lives, in terms of a *place* on the keyboard
/// rather than a character.
///
/// ⌘` is the right key on a US board. On a German one it is nearly unreachable:
/// ` is Shift + ´ and a dead key, so the shortcut needs three fingers and may
/// produce nothing at all (GitHub issue #2).
///
/// The fix is to name the key by position: the one immediately left of "1".
/// That is `kVK_ANSI_Grave` (50) on an ANSI board and `kVK_ISO_Section` (10) on
/// an ISO one — the two are *not* interchangeable, which is the trap. Measured
/// by translating both key codes through every installed layout:
///
///     layout    keyCode 50    keyCode 10
///     U.S.      `             §
///     German    <             (dead key, ^)
///     British   `             §
///
/// So on a German board keyCode 50 is the key beside the left shift, and the
/// one the issue asks for — ^, left of "1" — is keyCode 10. Binding 50
/// everywhere would have moved the shortcut to the wrong key and looked right
/// in a US test.
enum KeyboardLayout {
    /// The key left of "1" on the keyboard that is actually attached.
    static var terminalKeyCode: UInt16 {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
            ? UInt16(kVK_ISO_Section) : UInt16(kVK_ANSI_Grave)
    }

    /// What that key prints, for the menu to show: ` on US, ^ on German.
    /// Falls back to ` when the layout cannot be read.
    static var terminalKeyCharacter: Character {
        character(for: terminalKeyCode) ?? "`"
    }

    private static func character(for keyCode: UInt16) -> Character? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var state: UInt32 = 0
        var text = translate(keyCode, data: data, state: &state)
        // a dead key prints nothing until the next keystroke; ask it again with
        // a space to get the accent itself, which is what the menu should show
        if text.isEmpty, state != 0 {
            text = translate(UInt16(kVK_Space), data: data, state: &state)
        }
        return text.first
    }

    private static func translate(_ keyCode: UInt16, data: Data, state: inout UInt32) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        var localState = state
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0,
                                  UInt32(LMGetKbdType()), 0, &localState,
                                  buffer.count, &length, &buffer)
        }
        state = localState
        guard status == noErr else { return "" }
        return String(utf16CodeUnits: buffer, count: length).trimmingCharacters(in: .whitespaces)
    }
}
