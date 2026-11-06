import Foundation

enum Kind: Codable { case a, b }
struct Item {
  var id: Int
  var name: String
  var note: String?
  var tags: [String]
  var count: Int
  var flag: Bool
  var when: Date
  var kind: Kind
  var score: Double
  var child: Item2?
}
struct Item2 { var title: String; var n: Int }

func p01() -> Predicate<Item> { #Predicate<Item> { $0.id == 3 } }
func p02() -> Predicate<Item> { #Predicate<Item> { $0.name != "x" } }
func p03() -> Predicate<Item> { #Predicate<Item> { $0.count < 5 && $0.count >= 1 } }
func p04() -> Predicate<Item> { #Predicate<Item> { $0.flag || !$0.flag } }
func p05() -> Predicate<Item> { #Predicate<Item> { $0.name.contains("a") } }
func p06() -> Predicate<Item> { #Predicate<Item> { $0.name.localizedStandardContains("a") } }
func p07() -> Predicate<Item> { #Predicate<Item> { $0.name.hasPrefix("a") } }
func p08() -> Predicate<Item> { #Predicate<Item> { $0.tags.contains("a") } }
func p09(v: Int) -> Predicate<Item> { #Predicate<Item> { $0.id == v } }
func p10(v: Item) -> Predicate<Item> { #Predicate<Item> { $0.name == v.name } }
func p11() -> Predicate<Item> { #Predicate<Item> { item in item.id > 0 } }
func p12() -> Predicate<Item> { #Predicate<Item> { (item: Item) in item.id > 0 } }
func p13() -> Predicate<Item> { #Predicate<Item> { $0.note == nil } }
func p14() -> Predicate<Item> { #Predicate<Item> { $0.note != nil } }
func p15() -> Predicate<Item> { #Predicate<Item> { ($0.note ?? "") == "x" } }
func p16() -> Predicate<Item> { #Predicate<Item> { $0.child?.n == 2 } }
func p17() -> Predicate<Item> { #Predicate<Item> { $0.kind == .a } }
func p18() -> Predicate<Item> { #Predicate<Item> { $0.count + 1 > 3 } }
func p19() -> Predicate<Item> { #Predicate<Item> { $0.score * 2 > 3.5 } }
func p20() -> Predicate<Item> { #Predicate<Item> { $0.tags.isEmpty } }
func p21() -> Predicate<Item> { #Predicate<Item> { $0.tags.count > 1 } }
func p22(d: Date) -> Predicate<Item> { #Predicate<Item> { $0.when > d } }
func p23() -> Predicate<Item> { #Predicate<Item> { $0.flag ? $0.id > 1 : $0.id < 0 } }
func p24() -> Predicate<Item> { #Predicate<Item> { $0.id % 2 == 0 } }
func p25(ids: [Int]) -> Predicate<Item> { #Predicate<Item> { ids.contains($0.id) } }
func p26() -> Predicate<Item> { #Predicate<Item> { $0.tags.contains { $0 == "z" } } }
func p27() -> Predicate<Item> { #Predicate<Item> { if let n = $0.note { return n == "a" } else { return false } } }
func p28() -> Predicate<Item> { #Predicate<Item> { $0.name.lowercased() == "a" } }
func p29() -> Predicate<Item> { #Predicate<Item> { $0.name.count > 2 } }
func p30() -> Predicate<Item> { #Predicate<Item> { $0.id == 1 || ($0.id == 2 && $0.flag) } }
func p31() -> Predicate<Item> { #Predicate<Item> { _ in true } }
func p32() -> Predicate<Item> { #Predicate<Item> { $0.name.starts(with: "a") } }
func p33() -> Predicate<Item> { #Predicate<Item> { $0.tags.filter { $0 == "a" }.count > 0 } }
func p34() -> Predicate<Item> { #Predicate<Item> { $0.tags.allSatisfy { $0.count > 1 } } }
func p35() -> Predicate<Item> { #Predicate<Item> { $0.id == Int("3") } }
func p36() -> Predicate<Item> { #Predicate<Item> { $0.id >= 1 && $0.id <= 10 } }
func p37() -> Predicate<Item> { #Predicate<Item> { (1...5).contains($0.id) } }
func p38() -> Predicate<Item> { #Predicate<Item> { $0.name.caseInsensitiveCompare("a") == .orderedSame } }
func p39() -> Predicate<Item> { #Predicate<Item> { $0.name.range(of: "a") != nil } }
func p40(a: Int, b: Int) -> Predicate<Item> { #Predicate<Item> { $0.id == a + b } }

func multi() -> Predicate<Item, Item2> { #Predicate<Item, Item2> { a, b in a.name == b.title } }
func infer() -> Predicate<Item> { Predicate { (i: Item) in i.id == 1 } }
let expr = #Expression<Item, Int> { $0.id + 1 }
