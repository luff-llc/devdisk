import Foundation

/// Where the space is: a size tree that opens the big folders until every part over a threshold
/// is named, whether or not any rule knows about it.
public struct WhereNode: Codable, Sendable {
    public var path: String
    public var bytes: Int64
    public var children: [WhereNode]
}

public enum Where {
    /// Measures `root`'s children, then opens any child over `open` bytes, down to `depth` levels.
    public static func tree(_ root: String, depth: Int, open: Int64) -> WhereNode {
        let children = Files.children(root).filter { !Files.isSymlink($0) }
        let sizes = parallelMap(children, width: 12) { Walker.measure($0).total }
        var nodes: [WhereNode] = []
        let opened = parallelMap(Array(zip(children, sizes)), width: 4) { pair -> WhereNode in
            let (path, bytes) = pair
            if depth > 1, bytes >= open, isDirectory(path) {
                var node = tree(path, depth: depth - 1, open: open)
                node.bytes = bytes
                return node
            }
            return WhereNode(path: path, bytes: bytes, children: [])
        }
        nodes = opened.sorted { $0.bytes > $1.bytes }
        return WhereNode(path: root, bytes: sizes.reduce(0, +), children: nodes)
    }

    static func print(_ node: WhereNode, minimum: Int64, indent: String = "", out: inout [String]) {
        out.append("\(formatBytes(node.bytes).padding(toLength: 8, withPad: " ", startingAt: 0)) \(indent)\(indent.isEmpty ? node.path : (node.path as NSString).lastPathComponent)")
        let shown = node.children.filter { $0.bytes >= minimum }
        for child in shown { print(child, minimum: minimum, indent: indent + "  ", out: &out) }
        let rest = node.children.filter { $0.bytes < minimum }
        if !rest.isEmpty, node.children.count > shown.count {
            out.append("\(formatBytes(rest.reduce(0) { $0 + $1.bytes }).padding(toLength: 8, withPad: " ", startingAt: 0)) \(indent)  (\(rest.count) smaller)")
        }
    }
}
