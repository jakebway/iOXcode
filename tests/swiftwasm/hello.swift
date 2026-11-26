struct Point: Codable { var x: Int; var y: Int }
let items = (1...10).map { $0 * $0 }
print("hello from swift on wasm: \(items.reduce(0, +))")
print(String(describing: Point(x: 1, y: 2)))
let words = "the quick brown fox".split(separator: " ").map { $0.uppercased() }
print(words.joined(separator: "-"))
