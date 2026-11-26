@freestanding(expression)
macro stringify<T>(_ value: T) -> (T, String) = #externalMacro(module: "StringifyMacros", type: "StringifyMacro")

let (value, text) = #stringify(2 + 3)
print("macro says: \(value) from \"\(text)\"")
