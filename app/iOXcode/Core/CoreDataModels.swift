import Foundation
import CoreData

/// Replaces Xcode's data model compiler: reads `.xcdatamodeld` bundles, writes the Swift classes Xcode would generate
/// (codeGenerationType "class" or "category") and builds the compiled model (`.momd`) with CoreData itself.
enum DataModelCompiler {
    struct Attribute {
        var name: String, type: String, optional: Bool, scalar: Bool, defaultValue: String?, valueClass: String?
        var transformer: String?
    }
    struct Relationship {
        var name: String, destination: String, toMany: Bool, ordered: Bool, optional: Bool
        var inverseName: String?, inverseEntity: String?, deletion: String, minCount: Int, maxCount: Int
    }
    struct Entity {
        var name: String, className: String, parent: String?, codegen: String, isAbstract: Bool
        var attributes: [Attribute] = [], relationships: [Relationship] = []
    }

    final class Parser: NSObject, XMLParserDelegate {
        var entities: [Entity] = []
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            switch name {
            case "entity":
                let n = a["name"] ?? ""
                entities.append(Entity(name: n, className: a["representedClassName"] ?? n, parent: a["parentEntity"],
                                       codegen: a["codeGenerationType"] ?? "class", isAbstract: a["isAbstract"] == "YES"))
            case "attribute":
                guard !entities.isEmpty else { return }
                entities[entities.count - 1].attributes.append(Attribute(
                    name: a["name"] ?? "", type: a["attributeType"] ?? "String", optional: a["optional"] == "YES",
                    scalar: a["usesScalarValueType"] == "YES", defaultValue: a["defaultValueString"],
                    valueClass: a["customClassName"] ?? a["attributeValueClassName"], transformer: a["valueTransformerName"]))
            case "relationship":
                guard !entities.isEmpty else { return }
                entities[entities.count - 1].relationships.append(Relationship(
                    name: a["name"] ?? "", destination: a["destinationEntity"] ?? "", toMany: a["toMany"] == "YES",
                    ordered: a["ordered"] == "YES", optional: a["optional"] == "YES", inverseName: a["inverseName"],
                    inverseEntity: a["inverseEntity"], deletion: a["deletionRule"] ?? "Nullify",
                    minCount: Int(a["minCount"] ?? "") ?? 0, maxCount: Int(a["maxCount"] ?? "") ?? 0))
            default: break
            }
        }
    }

    static func findModels(under root: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
        for case let u as URL in en {
            let n = u.lastPathComponent
            if n.hasPrefix(".") || n == "Pods" || n == "build" { en.skipDescendants(); continue }
            if u.pathExtension == "xcdatamodeld" { out.append(u); en.skipDescendants() }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The version folder that is current (`.xccurrentversion`) or, without one, the last by name.
    static func currentVersion(of bundle: URL) -> URL? {
        let fm = FileManager.default
        let kids = ((try? fm.contentsOfDirectory(atPath: bundle.path)) ?? []).filter { $0.hasSuffix(".xcdatamodel") }.sorted()
        if let data = try? Data(contentsOf: bundle.appendingPathComponent(".xccurrentversion")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let name = plist["_XCCurrentVersionName"] as? String, kids.contains(name) {
            return bundle.appendingPathComponent(name)
        }
        return kids.last.map { bundle.appendingPathComponent($0) }
    }

    static func parse(_ version: URL) -> [Entity] {
        guard let data = try? Data(contentsOf: version.appendingPathComponent("contents")) else { return [] }
        let p = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        return p.entities
    }

    // MARK: Swift source

    static func swiftType(_ a: Attribute) -> String {
        let scalar = a.scalar
        switch a.type {
        case "String": return "String?"
        case "Integer 16": return scalar ? "Int16" : "NSNumber?"
        case "Integer 32": return scalar ? "Int32" : "NSNumber?"
        case "Integer 64": return scalar ? "Int64" : "NSNumber?"
        case "Double": return scalar ? "Double" : "NSNumber?"
        case "Float": return scalar ? "Float" : "NSNumber?"
        case "Boolean": return scalar ? "Bool" : "NSNumber?"
        case "Date": return "Date?"
        case "Binary": return "Data?"
        case "UUID": return "UUID?"
        case "URI": return "URL?"
        case "Decimal": return "NSDecimalNumber?"
        case "Transformable": return (a.valueClass.map { $0 + "?" }) ?? "NSObject?"
        default: return "NSObject?"
        }
    }

    static func source(for entities: [Entity]) -> String {
        var s = "import Foundation\nimport CoreData\n\n"
        let classOf = Dictionary(uniqueKeysWithValues: entities.map { ($0.name, $0.className) })
        for e in entities where e.codegen != "none" {
            let parent = e.parent.flatMap { classOf[$0] } ?? "NSManagedObject"
            if e.codegen == "class" || e.codegen.isEmpty {
                s += "@objc(\(e.className))\npublic class \(e.className): \(parent) {\n\n}\n\n"
            }
            s += "extension \(e.className) {\n\n"
            s += "    @nonobjc public class func fetchRequest() -> NSFetchRequest<\(e.className)> {\n"
            s += "        return NSFetchRequest<\(e.className)>(entityName: \"\(e.name)\")\n    }\n\n"
            for a in e.attributes { s += "    @NSManaged public var \(a.name): \(swiftType(a))\n" }
            for r in e.relationships {
                let dest = classOf[r.destination] ?? r.destination
                if r.toMany { s += "    @NSManaged public var \(r.name): \(r.ordered ? "NSOrderedSet" : "NSSet")?\n" }
                else { s += "    @NSManaged public var \(r.name): \(dest)?\n" }
            }
            s += "\n}\n\n"
            for r in e.relationships where r.toMany {
                let dest = classOf[r.destination] ?? r.destination
                let cap = r.name.prefix(1).uppercased() + r.name.dropFirst()
                s += "// MARK: Generated accessors for \(r.name)\nextension \(e.className) {\n"
                if r.ordered {
                    s += """
                        @objc(insertObject:in\(cap)AtIndex:)
                        @NSManaged public func insertInto\(cap)(_ value: \(dest), at idx: Int)
                        @objc(removeObjectFrom\(cap)AtIndex:)
                        @NSManaged public func removeFrom\(cap)(at idx: Int)
                        @objc(add\(cap)Object:)
                        @NSManaged public func addTo\(cap)(_ value: \(dest))
                        @objc(remove\(cap)Object:)
                        @NSManaged public func removeFrom\(cap)(_ value: \(dest))
                        @objc(add\(cap):)
                        @NSManaged public func addTo\(cap)(_ values: NSOrderedSet)
                        @objc(remove\(cap):)
                        @NSManaged public func removeFrom\(cap)(_ values: NSOrderedSet)

                    """
                } else {
                    s += """
                        @objc(add\(cap)Object:)
                        @NSManaged public func addTo\(cap)(_ value: \(dest))
                        @objc(remove\(cap)Object:)
                        @NSManaged public func removeFrom\(cap)(_ value: \(dest))
                        @objc(add\(cap):)
                        @NSManaged public func addTo\(cap)(_ values: NSSet)
                        @objc(remove\(cap):)
                        @NSManaged public func removeFrom\(cap)(_ values: NSSet)

                    """
                }
                s += "}\n\n"
            }
        }
        return s
    }

    // MARK: compiled model

    static func attributeType(_ t: String) -> NSAttributeType {
        switch t {
        case "String": return .stringAttributeType
        case "Integer 16": return .integer16AttributeType
        case "Integer 32": return .integer32AttributeType
        case "Integer 64": return .integer64AttributeType
        case "Double": return .doubleAttributeType
        case "Float": return .floatAttributeType
        case "Boolean": return .booleanAttributeType
        case "Date": return .dateAttributeType
        case "Binary": return .binaryDataAttributeType
        case "UUID": return .UUIDAttributeType
        case "URI": return .URIAttributeType
        case "Decimal": return .decimalAttributeType
        case "Transformable": return .transformableAttributeType
        default: return .undefinedAttributeType
        }
    }

    static func model(from entities: [Entity]) -> NSManagedObjectModel {
        let m = NSManagedObjectModel()
        var byName: [String: NSEntityDescription] = [:]
        for e in entities {
            let d = NSEntityDescription()
            d.name = e.name
            d.managedObjectClassName = e.className
            d.isAbstract = e.isAbstract
            var props: [NSPropertyDescription] = []
            for a in e.attributes {
                let p = NSAttributeDescription()
                p.name = a.name
                p.attributeType = attributeType(a.type)
                p.isOptional = a.optional
                if let dv = a.defaultValue { p.defaultValue = defaultObject(dv, type: p.attributeType) }
                if p.attributeType == .transformableAttributeType {
                    if let vc = a.valueClass { p.attributeValueClassName = vc }
                    if let t = a.transformer { p.valueTransformerName = t }
                }
                props.append(p)
            }
            d.properties = props
            byName[e.name] = d
        }
        for e in entities {
            guard let d = byName[e.name] else { continue }
            if let pn = e.parent, let pd = byName[pn] { pd.subentities = pd.subentities + [d] }
            var rels: [NSPropertyDescription] = []
            for r in e.relationships {
                let p = NSRelationshipDescription()
                p.name = r.name
                p.destinationEntity = byName[r.destination]
                p.isOptional = r.optional
                p.isOrdered = r.ordered
                p.minCount = r.minCount
                p.maxCount = r.toMany ? r.maxCount : 1
                p.deleteRule = ["Cascade": .cascadeDeleteRule, "Deny": .denyDeleteRule, "No Action": .noActionDeleteRule][r.deletion] ?? .nullifyDeleteRule
                rels.append(p)
            }
            d.properties = d.properties + rels
        }
        for e in entities {
            guard let d = byName[e.name] else { continue }
            for r in e.relationships {
                guard let inv = r.inverseName,
                      let p = d.relationshipsByName[r.name],
                      let other = byName[r.inverseEntity ?? r.destination]?.relationshipsByName[inv] else { continue }
                p.inverseRelationship = other
            }
        }
        m.entities = entities.compactMap { byName[$0.name] }
        return m
    }

    static func defaultObject(_ s: String, type: NSAttributeType) -> Any? {
        switch type {
        case .stringAttributeType: return s
        case .booleanAttributeType: return NSNumber(value: s.uppercased() == "YES" || s == "1" || s.lowercased() == "true")
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: return Int(s).map { NSNumber(value: $0) }
        case .doubleAttributeType, .floatAttributeType: return Double(s).map { NSNumber(value: $0) }
        default: return nil
        }
    }

    /// Writes `<Name>.momd/<Version>.mom` and `VersionInfo.plist` into the app.
    static func writeCompiled(bundle: URL, version: URL, entities: [Entity], into app: URL) throws {
        let name = bundle.deletingPathExtension().lastPathComponent
        let ver = version.deletingPathExtension().lastPathComponent
        let momd = app.appendingPathComponent("\(name).momd", isDirectory: true)
        try FileManager.default.createDirectory(at: momd, withIntermediateDirectories: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: model(from: entities), requiringSecureCoding: false)
        try data.write(to: momd.appendingPathComponent("\(ver).mom"))
        let info: [String: Any] = ["NSManagedObjectModel_CurrentVersionName": ver,
                                   "NSManagedObjectModel_VersionHashes": [String: Any]()]
        try (info as NSDictionary).write(to: momd.appendingPathComponent("VersionInfo.plist"))
    }
}
