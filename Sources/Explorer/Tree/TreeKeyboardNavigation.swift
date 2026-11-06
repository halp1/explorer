import AppKit

/// Plans tree-only shortcuts without changing outline expansion or selection.
enum TreeKeyboardNavigation {
    enum Action: Equatable {
        case jump(Int)
        case toggleGroup(Int)
    }

    struct Jump {
        let target: TreeNode
        let ancestorsToExpand: [TreeNode]
    }

    static func action(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Action? {
        let shortcutModifiers = modifiers.intersection([.command, .option, .control, .shift])
        guard shortcutModifiers == .option else { return nil }
        switch keyCode {
        case 126: return .jump(-1)
        case 125: return .jump(1)
        default:
            guard let characters, let digit = Int(characters), (1...4).contains(digit) else { return nil }
            return .toggleGroup(digit - 1)
        }
    }

    /// The caller supplies visible roots in outline order, excluding disabled or hidden sections.
    static func group(at index: Int, roots: [TreeNode]) -> TreeNode? {
        let groups = roots.filter { node in
            if case .section = node.kind { return true }
            return false
        }
        guard groups.indices.contains(index) else { return nil }
        return groups[index]
    }

    static func jump(direction: Int, roots: [TreeNode], selection: TreeNode?) -> Jump? {
        guard direction != 0 else { return nil }
        var selectedRoot = selection
        while let parent = selectedRoot?.parent { selectedRoot = parent }
        let currentIndex = selectedRoot.flatMap { selected in roots.firstIndex { $0 === selected } }
        let step = direction > 0 ? 1 : -1
        var index = currentIndex.map { $0 + step } ?? (step > 0 ? 0 : roots.count - 1)
        while roots.indices.contains(index) {
            if let target = firstNavigable(in: roots[index]) { return target }
            index += step
        }
        return nil
    }

    private static func firstNavigable(in node: TreeNode) -> Jump? {
        if node.isNodeSelectable { return Jump(target: node, ancestorsToExpand: []) }
        // Group children are already loaded. Never descend into a placeholder or load a folder
        // merely to jump past it: navigable roots should be selected themselves.
        guard case .section = node.kind else { return nil }
        for child in node.children ?? [] {
            if let descendant = firstNavigable(in: child) {
                return Jump(target: descendant.target, ancestorsToExpand: [node] + descendant.ancestorsToExpand)
            }
        }
        return nil
    }
}
