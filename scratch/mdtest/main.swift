import Foundation
let a = CommandLine.arguments
let text = try! String(contentsOfFile: a[1], encoding: .utf8)
let t0 = Date()
let html = Markdown.page(text, baseDir: URL(fileURLWithPath: a[3], isDirectory: true))
try! html.write(toFile: a[2], atomically: true, encoding: .utf8)
print("converted \(text.count) chars in \(Date().timeIntervalSince(t0))s -> \(html.count) chars")
