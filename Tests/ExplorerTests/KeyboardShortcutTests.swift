import AppKit
import ExplorerKit
import XCTest
@testable import Explorer

final class KeyboardShortcutTests: XCTestCase {
    private func resolve(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                         context: KeyboardShortcuts.Context = .files, returnAction: ReturnAction = .open,
                         trash: Bool = false, back: Bool = false, rtl: Bool = false,
                         characters: String? = nil) -> KeyboardShortcuts.Command? {
        KeyboardShortcuts.resolve(keyCode: code, characters: characters, modifiers: modifiers,
            context: context, returnAction: returnAction, trashWithDelete: trash,
            backWithDelete: back, rightToLeft: rtl)
    }

    func testReturnAndDeletePreferencesDoNotAdmitExtraModifiers() {
        for code: UInt16 in [36, 76] {
            for context: KeyboardShortcuts.Context in [.files, .table, .tree] {
                XCTAssertEqual(resolve(code, context: context), .open)
                XCTAssertEqual(resolve(code, context: context, returnAction: .rename), .rename)
                XCTAssertEqual(resolve(code, .command, context: context), .rename)
                XCTAssertEqual(resolve(code, .shift, context: context), .rename)
                XCTAssertNil(resolve(code, [.command, .shift], context: context))
                XCTAssertNil(resolve(code, .option, context: context))
            }
        }
        for context: KeyboardShortcuts.Context in [.files, .table, .tree] {
            XCTAssertNil(resolve(51, context: context))
            XCTAssertEqual(resolve(51, context: context, back: true), .back)
            XCTAssertEqual(resolve(51, context: context, trash: true), .trash)
            XCTAssertEqual(resolve(51, context: context, trash: true, back: true), .trash)
            XCTAssertNil(resolve(51, .shift, context: context, trash: true, back: true))
            XCTAssertEqual(resolve(117, context: context), .trash)
            XCTAssertEqual(resolve(117, .option, context: context), .deletePermanently)
            XCTAssertNil(resolve(117, [.option, .shift], context: context))
        }
    }

    func testIncidentalFlagsAreIgnoredButModifiedFunctionKeysAreNotShortcuts() {
        let incidental: NSEvent.ModifierFlags = [.function, .numericPad, .capsLock]
        for (code, command): (UInt16, KeyboardShortcuts.Command) in [(120, .rename), (96, .refresh), (49, .quickLook)] {
            XCTAssertEqual(resolve(code, incidental), command)
            for extra: NSEvent.ModifierFlags in [.command, .control, .shift, .option, [.command, .option]] {
                XCTAssertNil(resolve(code, incidental.union(extra)))
            }
        }
        XCTAssertEqual(resolve(125, [.command, .function, .numericPad]), .open)
        XCTAssertEqual(resolve(126, [.command, .capsLock]), .up)
        XCTAssertNil(resolve(125, [.command, .option]))
    }

    func testShelfUsesOnlyTrailingArrowAndSizesOnlyUseTableContext() {
        for rtl in [false, true] {
            XCTAssertEqual(resolve(rtl ? 123 : 124, .command, rtl: rtl), .shelf)
            XCTAssertNil(resolve(rtl ? 124 : 123, .command, rtl: rtl))
            XCTAssertNil(resolve(rtl ? 123 : 124, [.command, .shift], rtl: rtl))
        }
        XCTAssertEqual(resolve(24, [.capsLock], context: .table, characters: "="), .calculateSizes)
        for context: KeyboardShortcuts.Context in [.files, .tree, .editor] {
            XCTAssertNil(resolve(24, context: context, characters: "="))
        }
        XCTAssertNil(resolve(24, .command, context: .table, characters: "="))
        XCTAssertNil(resolve(24, context: .table, characters: "+"))
    }

    func testFieldEditorNeverResolvesFileActions() {
        for code: UInt16 in [36, 76, 49, 120, 96, 51, 117, 123, 124, 125, 126] {
            for modifiers: NSEvent.ModifierFlags in [[], .command, .shift, .option, [.function, .numericPad]] {
                XCTAssertNil(resolve(code, modifiers, context: .editor, returnAction: .rename, trash: true, back: true))
            }
        }
    }
}
