import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

protocol MCJSON {
    static var mcHasReferences: Bool { get }
    static func fromJSON(_ value: Any) throws -> Self
    func toJSON() throws -> Any
    func mcProbe(_ visited: inout Set<ObjectIdentifier>) -> Bool
}
extension MCJSON {
    static var mcHasReferences: Bool { false }
    func mcProbe(_ visited: inout Set<ObjectIdentifier>) -> Bool { false }
}
func mcEncoded<T: MCJSON>(_ value: T) throws -> Any {
    if T.mcHasReferences && !mcContext.graph {
        var visited = Set<ObjectIdentifier>()
        mcContext.graph = value.mcProbe(&visited)
    }
    return try value.toJSON()
}
func mcError(_ text: String) -> NSError {
    NSError(domain: "meatcode", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}

private func mcIdentity(_ value: Any?) throws -> String {
    guard let value = value else { throw mcError("missing identity id") }
    if let text = value as? String, !text.isEmpty { return "s:" + text }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
       number.objCType.pointee != 100, number.objCType.pointee != 102,
       number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue {
        return "i:" + number.stringValue
    }
    throw mcError("identity id must be a nonempty string or integer")
}
final class MCDecodeContext {
    var definitions: [String: [String: Any]] = [:]
    var instances: [String: AnyObject] = [:]
    var outputIDs: [ObjectIdentifier: (Int, AnyObject)] = [:]
    var nextOutputID = 1
    var graph = false
    func index(_ value: Any) throws {
        if let list = value as? [Any] { for item in list { try index(item) }; return }
        guard let object = value as? [String: Any] else { return }
        if let reference = object["$ref"] {
            guard object.count == 1 else { throw mcError("reference object must contain only $ref") }
            _ = try mcIdentity(reference)
        }
        if object["$id"] != nil {
            let id = try mcIdentity(object["$id"])
            guard definitions[id] == nil else { throw mcError("duplicate identity id") }
            definitions[id] = object
            graph = true
        }
        for item in object.values { try index(item) }
    }
}
private var mcContext = MCDecodeContext()
func mcBegin(_ values: [Any]) throws {
    mcContext = MCDecodeContext()
    try mcContext.index(values)
}
func mcReference<T: AnyObject>(_ value: Any, _ type: T.Type,
    allocate: () throws -> T, populate: (T, [String: Any]) throws -> Void) throws -> AnyObject {
    guard let object = value as? [String: Any] else { throw mcError("expected an identity object") }
    let isRef = object["$ref"] != nil
    let id = try mcIdentity(object[isRef ? "$ref" : "$id"])
    if isRef && object.count != 1 { throw mcError("reference object must contain only $ref") }
    guard let definition = mcContext.definitions[id] else { throw mcError("unresolved identity reference") }
    if let instance = mcContext.instances[id] {
        guard let typed = instance as? T else { throw mcError("identity reference has the wrong type") }
        return typed
    }
    let shell = try allocate()
    mcContext.instances[id] = shell
    var fields = definition
    fields.removeValue(forKey: "$id")
    try populate(shell, fields)
    guard let typed = shell as? T else { throw mcError("identity reference has the wrong type") }
    return typed
}
func mcEncodeReference<T: AnyObject>(_ value: T, fields: () throws -> [String: Any],
    positional: () throws -> [Any]) rethrows -> Any {
    if !mcContext.graph { return try positional() }
    let identity = ObjectIdentifier(value)
    if let (id, _) = mcContext.outputIDs[identity] { return ["$ref": id] }
    let id = mcContext.nextOutputID
    mcContext.nextOutputID += 1
    mcContext.outputIDs[identity] = (id, value)
    var object: [String: Any] = ["$id": id]
    object.merge(try fields(), uniquingKeysWith: { _, new in new })
    return object
}
extension MCJSON where Self: Codable {
    static func fromJSON(_ value: Any) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }
    func toJSON() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self), options: [.fragmentsAllowed])
    }
}
extension Int: MCJSON {}
extension Int8: MCJSON {}
extension Int16: MCJSON {}
extension Int32: MCJSON {}
extension Int64: MCJSON {}
extension UInt: MCJSON {}
extension UInt8: MCJSON {}
extension UInt16: MCJSON {}
extension UInt32: MCJSON {}
extension UInt64: MCJSON {}
extension Double: MCJSON {}
extension Float: MCJSON {}
extension Bool: MCJSON {}
extension String: MCJSON {}
extension Character: MCJSON {
    static func fromJSON(_ value: Any) throws -> Character {
        guard let text = value as? String, text.count == 1 else { throw mcError("expected a character") }
        return text.first!
    }
    func toJSON() -> Any { String(self) }
}
extension Array: MCJSON where Element: MCJSON {
    static var mcHasReferences: Bool { Element.mcHasReferences }
    static func fromJSON(_ value: Any) throws -> [Element] {
        guard let values = value as? [Any] else { throw mcError("expected an array") }
        return try values.map { try Element.fromJSON($0) }
    }
    func toJSON() throws -> Any { try map { try $0.toJSON() } }
    func mcProbe(_ visited: inout Set<ObjectIdentifier>) -> Bool {
        guard Element.mcHasReferences else { return false }
        var shared = false
        for value in self { if value.mcProbe(&visited) { shared = true } }
        return shared
    }
}

extension Dictionary: MCJSON where Key == String, Value: MCJSON {
    static var mcHasReferences: Bool { Value.mcHasReferences }
    static func fromJSON(_ value: Any) throws -> [String: Value] {
        guard let object = value as? [String: Any] else { throw mcError("expected a string-keyed object") }
        var result: [String: Value] = [:]
        for (key, item) in object { result[key] = try Value.fromJSON(item) }
        return result
    }
    func toJSON() throws -> Any {
        var result: [String: Any] = [:]
        for key in keys.sorted() { result[key] = try self[key]!.toJSON() }
        return result
    }
    func mcProbe(_ visited: inout Set<ObjectIdentifier>) -> Bool {
        guard Value.mcHasReferences else { return false }
        var shared = false
        for key in keys.sorted() { if self[key]!.mcProbe(&visited) { shared = true } }
        return shared
    }
}
extension Optional: MCJSON where Wrapped: MCJSON {
    static var mcHasReferences: Bool { Wrapped.mcHasReferences }
    static func fromJSON(_ value: Any) throws -> Wrapped? {
        if value is NSNull { return nil }
        if (Wrapped.self == ListNode.self || Wrapped.self == TreeNode.self), let array = value as? [Any], array.isEmpty { return nil }
        return try Wrapped.fromJSON(value)
    }
    func toJSON() throws -> Any {
        if let value = self { return try value.toJSON() }
        return (Wrapped.self == ListNode.self || Wrapped.self == TreeNode.self) ? [Any]() : NSNull()
    }
    func mcProbe(_ visited: inout Set<ObjectIdentifier>) -> Bool {
        if let value = self { return value.mcProbe(&visited) }
        return false
    }
}
final class ListNode: MCJSON {
    var val: Int
    var next: ListNode?
    init(_ val: Int = 0, _ next: ListNode? = nil) { self.val = val; self.next = next }
    static func fromJSON(_ value: Any) throws -> ListNode {
        guard let values = value as? [Any], !values.isEmpty else { throw mcError("expected a nonempty linked list") }
        let head = ListNode(try Int.fromJSON(values[0]))
        var tail: ListNode = head
        for value in values.dropFirst() { let node = ListNode(try Int.fromJSON(value)); tail.next = node; tail = node }
        return head
    }
    func toJSON() throws -> Any {
        var values: [Int] = [], node: ListNode? = self
        var seen = Set<ObjectIdentifier>()
        while let current = node {
            guard seen.insert(ObjectIdentifier(current)).inserted else { throw mcError("solution returned a cyclic linked list") }
            values.append(current.val); node = current.next
        }
        return values
    }
}
final class TreeNode: MCJSON {
    var val: Int
    var left: TreeNode?
    var right: TreeNode?
    init(_ val: Int = 0, _ left: TreeNode? = nil, _ right: TreeNode? = nil) { self.val = val; self.left = left; self.right = right }
    static func fromJSON(_ value: Any) throws -> TreeNode {
        guard let values = value as? [Any], !values.isEmpty, !(values[0] is NSNull) else { throw mcError("expected a nonempty tree") }
        let root = TreeNode(try Int.fromJSON(values[0]))
        var queue: [TreeNode] = [root], next = 0, index = 1
        while next < queue.count && index < values.count {
            let node = queue[next]; next += 1
            if !(values[index] is NSNull) { node.left = TreeNode(try Int.fromJSON(values[index])); queue.append(node.left!) }
            index += 1
            if index < values.count {
                if !(values[index] is NSNull) { node.right = TreeNode(try Int.fromJSON(values[index])); queue.append(node.right!) }
                index += 1
            }
        }
        if index < values.count { throw mcError("tree contains unreachable nodes") }
        return root
    }
    func toJSON() throws -> Any {
        var queue: [TreeNode?] = [self], values: [Any] = [], next = 0
        var seen = Set<ObjectIdentifier>()
        while next < queue.count {
            let node = queue[next]; next += 1
            if let node = node {
                guard seen.insert(ObjectIdentifier(node)).inserted else { throw mcError("solution returned a cyclic tree") }
                values.append(node.val); queue.append(node.left); queue.append(node.right)
            } else { values.append(NSNull()) }
        }
        while values.last is NSNull { values.removeLast() }
        return values
    }
}
func mcDecode<T: MCJSON>(_ value: Any, _ type: T.Type) throws -> T { try T.fromJSON(value) }
func mcNodeReference<T: MCJSON>(_ value: Any, _ type: T.Type, _ root: TreeNode?) throws -> T {
    guard value is NSNumber else { return try T.fromJSON(value) }
    let target = try Int.fromJSON(value)
    var pending: [TreeNode] = root.map { [$0] } ?? []
    while let node = pending.popLast() {
        if node.val == target, let result = node as? T { return result }
        if let left = node.left { pending.append(left) }
        if let right = node.right { pending.append(right) }
    }
    throw mcError("tree node reference not found: \(target)")
}
func mcNodeReference<T: MCJSON>(_ value: Any, _ type: T.Type, _ head: ListNode?) throws -> T {
    guard value is NSNumber else { return try T.fromJSON(value) }
    let target = try Int.fromJSON(value)
    var current = head
    while let node = current {
        if node.val == target, let result = node as? T { return result }
        current = node.next
    }
    throw mcError("list node reference not found: \(target)")
}
func mcText(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
}
func mcRead(_ dir: String, _ name: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name)), options: [.fragmentsAllowed])
}
func mcCapture<T>(_ dir: String, _ body: () throws -> T) throws -> (T, String) {
    let path = URL(fileURLWithPath: dir).appendingPathComponent("stdout-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw mcError("could not capture stdout") }
    let file = try FileHandle(forWritingTo: path)
    fflush(stdout)
    let saved = dup(STDOUT_FILENO)
    guard saved >= 0 else { try? file.close(); try? FileManager.default.removeItem(at: path); throw mcError("could not capture stdout") }
    defer {
        fflush(stdout); dup2(saved, STDOUT_FILENO); close(saved)
        try? file.close(); try? FileManager.default.removeItem(at: path)
    }
    guard dup2(file.fileDescriptor, STDOUT_FILENO) >= 0 else { throw mcError("could not capture stdout") }
    let value = try body()
    fflush(stdout)
    let text = String(decoding: try Data(contentsOf: path), as: UTF8.self)
    return (value, text)
}
