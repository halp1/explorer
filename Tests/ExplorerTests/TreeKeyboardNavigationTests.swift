import AppKit
import XCTest
@testable import Explorer

final class TreeKeyboardNavigationTests: XCTestCase {
    func testOnlyExactOptionShortcutsIgnoreNonShortcutFlags() {
        let shortcuts: [(UInt16, String?, TreeKeyboardNavigation.Action)] = [
            (126, nil, .jump(-1)),
            (125, nil, .jump(1)),
            (18, "1", .toggleGroup(0)),
            (19, "2", .toggleGroup(1)),
            (20, "3", .toggleGroup(2)),
            (21, "4", .toggleGroup(3)),
        ]
        let acceptedModifiers: [NSEvent.ModifierFlags] = [.option, [.option, .numericPad, .function, .capsLock]]
        let rejectedModifiers: [NSEvent.ModifierFlags] = [
            [], .command, .shift, .control, [.option, .command], [.option, .control],
            [.option, .shift], [.option, .control, .shift],
        ]
        for (keyCode, characters, expected) in shortcuts {
            for modifiers in acceptedModifiers {
                XCTAssertEqual(TreeKeyboardNavigation.action(keyCode: keyCode, characters: characters, modifiers: modifiers), expected)
            }
            for modifiers in rejectedModifiers {
                XCTAssertNil(TreeKeyboardNavigation.action(keyCode: keyCode, characters: characters, modifiers: modifiers))
            }
        }
        let unhandledCharacters: [String?] = [nil, "", "0", "5", "x"]
        for characters in unhandledCharacters {
            XCTAssertNil(TreeKeyboardNavigation.action(keyCode: 18, characters: characters, modifiers: .option))
        }
    }

    func testNumberedGroupsExcludeNavigableRootsAndFollowVisibleOrder() {
        let favorites = group("favorites")
        let tags = group("tags")
        let ratings = group("ratings")
        let searches = group("searches")
        let roots = [folder("home"), favorites, folder("drive"), tags, TreeNode(.trash, title: "Trash"), ratings, searches]
        for (index, expected) in [favorites, tags, ratings, searches].enumerated() {
            XCTAssertTrue(TreeKeyboardNavigation.group(at: index, roots: roots) === expected)
        }
        XCTAssertNil(TreeKeyboardNavigation.group(at: -1, roots: roots))
        XCTAssertNil(TreeKeyboardNavigation.group(at: 4, roots: roots))
        XCTAssertNil(TreeKeyboardNavigation.group(at: 0, roots: []))
        // A hidden group is absent from the visible roots and consumes no shortcut number.
        let reorderedVisibleRoots = [searches, folder("home"), favorites, ratings]
        XCTAssertTrue(TreeKeyboardNavigation.group(at: 0, roots: reorderedVisibleRoots) === searches)
        XCTAssertTrue(TreeKeyboardNavigation.group(at: 1, roots: reorderedVisibleRoots) === favorites)
        XCTAssertTrue(TreeKeyboardNavigation.group(at: 2, roots: reorderedVisibleRoots) === ratings)
        XCTAssertNil(TreeKeyboardNavigation.group(at: 3, roots: reorderedVisibleRoots))
    }

    func testJumpsSelectRootsOrFirstNavigableDescendantAndSkipEmptyGroups() throws {
        let homeChild = folder("home-child")
        let home = folder("home", children: [homeChild])
        let placeholder = TreeNode(.placeholder("Loading"), title: "Loading")
        let firstFavorite = folder("favorite")
        let deepFavorite = folder("deep-favorite")
        firstFavorite.children = [deepFavorite]
        deepFavorite.parent = firstFavorite
        let nested = group("nested", children: [firstFavorite])
        let favorites = group("favorites", children: [placeholder, group("empty-nested"), nested, folder("later-favorite")])
        let drive = folder("drive", children: [folder("drive-child")])
        let roots = [group("empty-first"), home, group("empty-middle"), favorites, drive, group("empty-last")]

        let toHome = try XCTUnwrap(TreeKeyboardNavigation.jump(direction: 1, roots: roots, selection: nil))
        XCTAssertTrue(toHome.target === home)
        XCTAssertTrue(toHome.ancestorsToExpand.isEmpty)
        let toFavorite = try XCTUnwrap(TreeKeyboardNavigation.jump(direction: 1, roots: roots, selection: homeChild))
        XCTAssertTrue(toFavorite.target === firstFavorite)
        XCTAssertEqual(toFavorite.ancestorsToExpand.count, 2)
        XCTAssertTrue(toFavorite.ancestorsToExpand[0] === favorites)
        XCTAssertTrue(toFavorite.ancestorsToExpand[1] === nested)
        let toDrive = try XCTUnwrap(TreeKeyboardNavigation.jump(direction: 1, roots: roots, selection: deepFavorite))
        XCTAssertTrue(toDrive.target === drive)
        XCTAssertTrue(toDrive.ancestorsToExpand.isEmpty)
        let backToFavorite = try XCTUnwrap(TreeKeyboardNavigation.jump(direction: -1, roots: roots, selection: drive))
        XCTAssertTrue(backToFavorite.target === firstFavorite)
        let backToHome = try XCTUnwrap(TreeKeyboardNavigation.jump(direction: -1, roots: roots, selection: deepFavorite))
        XCTAssertTrue(backToHome.target === home)
        // Planning expansion must not mutate the model or depend on outline expansion state.
        XCTAssertTrue(favorites.children?.first === placeholder)
        XCTAssertTrue(nested.children?.first === firstFavorite)
    }

    func testJumpsStopAtBoundsAndStartFromEitherEndWithoutSelection() throws {
        let first = folder("first")
        let last = TreeNode(.trash, title: "Trash")
        let roots = [group("empty-first"), first, group("empty-middle"), last, group("empty-last")]
        XCTAssertTrue(try XCTUnwrap(TreeKeyboardNavigation.jump(direction: 1, roots: roots, selection: nil)).target === first)
        XCTAssertTrue(try XCTUnwrap(TreeKeyboardNavigation.jump(direction: -1, roots: roots, selection: nil)).target === last)
        XCTAssertNil(TreeKeyboardNavigation.jump(direction: -1, roots: roots, selection: first))
        XCTAssertNil(TreeKeyboardNavigation.jump(direction: 1, roots: roots, selection: last))
        XCTAssertNil(TreeKeyboardNavigation.jump(direction: 0, roots: roots, selection: first))
        for direction in [-1, 1] {
            XCTAssertNil(TreeKeyboardNavigation.jump(direction: direction, roots: [], selection: nil))
            XCTAssertNil(TreeKeyboardNavigation.jump(direction: direction, roots: [group("empty")], selection: nil))
        }
    }

    private func folder(_ name: String, children: [TreeNode]? = nil) -> TreeNode {
        let node = TreeNode(.folder(URL(fileURLWithPath: "/tree-shortcut-tests/" + name)), title: name)
        node.children = children
        children?.forEach { $0.parent = node }
        return node
    }

    private func group(_ name: String, children: [TreeNode] = []) -> TreeNode {
        let node = TreeNode(.section(name), title: name)
        node.children = children
        children.forEach { $0.parent = node }
        return node
    }
}
