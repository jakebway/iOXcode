import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct StringifyMacro: ExpressionMacro {
    public static func expansion(of node: some FreestandingMacroExpansionSyntax,
                                 in context: some MacroExpansionContext) throws -> ExprSyntax {
        guard let argument = node.arguments.first?.expression else { fatalError("no argument") }
        return "(\(argument), \(literal: argument.description))"
    }
}

@main
struct Plugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [StringifyMacro.self]
}
