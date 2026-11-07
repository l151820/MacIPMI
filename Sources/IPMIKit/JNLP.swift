import Foundation

/// Parsed contents of a Java Web Start (.jnlp) file.
public struct JNLPDescriptor: Sendable {
    public var codebase: URL?
    public var mainJar: String?
    public var mainClass: String?
    public var arguments: [String] = []
    public var nativeLibs: [String] = []
    public var properties: [(String, String)] = []

    public static func parse(_ data: Data) throws -> JNLPDescriptor {
        let delegate = JNLPParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw IPMIError.malformed("JNLP nicht lesbar: \(parser.parserError?.localizedDescription ?? "?")")
        }
        guard delegate.result.mainJar != nil, delegate.result.mainClass != nil else {
            throw IPMIError.malformed("JNLP enthält kein Haupt-JAR oder keine Main-Class")
        }
        return delegate.result
    }
}

private final class JNLPParserDelegate: NSObject, XMLParserDelegate {
    var result = JNLPDescriptor()
    private var inArgument = false
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "jnlp":
            if let cb = a["codebase"] {
                result.codebase = URL(string: cb.hasSuffix("/") ? cb : cb + "/")
            }
        case "jar":
            if let href = a["href"], result.mainJar == nil || a["main"] == "true" { result.mainJar = href }
        case "nativelib":
            if let href = a["href"], !result.nativeLibs.contains(href) { result.nativeLibs.append(href) }
        case "application-desc":
            result.mainClass = a["main-class"]
        case "property":
            if let n = a["name"], let v = a["value"] { result.properties.append((n, v)) }
        case "argument":
            inArgument = true
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inArgument { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "argument" {
            result.arguments.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            inArgument = false
        }
    }
}
