import Foundation

// TileSelection driven as the tile view drives it. A folder of 11 tiles, 4
// across:   a b c d
//           e f g h
//           i j k
// Run with Support/Tiles/tests/run.sh.

let order = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"]
var failures = 0, checks = 0
func check(_ condition: Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !condition { failures += 1; print("FAIL line \(line): \(what)") }
}
func scenario(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}
func at(_ cursor: String?, marks: Set<String> = []) -> TileSelection {
    TileSelection(cursor: cursor, marks: marks)
}
func moved(_ s: TileSelection, _ m: TileSelection.Move, extend: Bool = false) -> TileSelection {
    var s = s; s.move(m, order: order, columns: 4, extend: extend); return s
}

scenario("the arrows move in four directions") {
    check(moved(at("f"), .left).cursor == "e", "left")
    check(moved(at("f"), .right).cursor == "g", "right")
    check(moved(at("f"), .up).cursor == "b", "up a row")
    check(moved(at("f"), .down).cursor == "j", "down a row")
    check(moved(at("a"), .left).cursor == "a", "stops at the first")
    check(moved(at("k"), .right).cursor == "k", "stops at the last")
    check(moved(at("b"), .up).cursor == "b", "nothing above the top row")
    check(moved(at("j"), .down).cursor == "j", "nothing below the bottom row")
    check(moved(at("e"), .right).cursor == "f" && moved(at("d"), .right).cursor == "e", "right wraps to the next row")
}

scenario("down onto a short last row goes to its last tile") {
    check(moved(at("h"), .down).cursor == "k", "h is above nothing: k, as in Finder")
    check(moved(at("g"), .down).cursor == "k", "g: k")
}

scenario("home and end, and no cursor yet") {
    check(moved(at("g"), .first).cursor == "a", "home")
    check(moved(at("c"), .last).cursor == "k", "end")
    check(moved(at(nil), .down).cursor == "a", "the first key lands on the first tile")
    var empty = TileSelection()
    empty.move(.down, order: [], columns: 4, extend: false)
    check(empty.cursor == nil, "an empty folder: nothing")
}

scenario("with nothing marked, the selection is the cursor's tile") {
    let s = moved(at("a"), .right)
    check(s.selection == ["b"], "\(s.selection)")
}

scenario("Space marks tiles far apart; the cursor moves on without them") {
    var s = at("a")
    s.toggleMark()                                   // a
    s = moved(moved(s, .down), .right)               // f
    s.toggleMark()                                   // a, f
    s = moved(s, .down)                              // j
    check(s.selection == ["a", "f"], "the marks, not the cursor: \(s.selection)")
    s.toggleMark()
    check(s.selection == ["a", "f", "j"], "three marked")
    s = moved(s, .up)
    s.toggleMark()                                   // f off
    check(s.selection == ["a", "j"], "Space again unmarks: \(s.selection)")
    s.marks = []
    check(s.selection == [s.cursor!], "Esc: the cursor's tile again")
}

scenario("unmarking the last mark falls back to the cursor") {
    var s = at("c")
    s.toggleMark(); s.toggleMark()
    check(s.marks.isEmpty && s.selection == ["c"], "\(s.selection)")
}

scenario("⇧-arrows mark what they pass over") {
    var s = moved(at("b"), .right, extend: true)
    check(s.selection == ["b", "c"], "\(s.selection)")
    s = moved(s, .down, extend: true)
    check(s.selection == ["b", "c", "d", "e", "f", "g"], "a row down marks the run: \(s.selection)")
    check(s.cursor == "g", "cursor at g")
}

scenario("clicks") {
    var s = at("b", marks: ["a", "c"])
    s.click("f", order: order, command: false, shift: false)
    check(s.selection == ["f"] && s.cursor == "f", "a plain click: that tile alone")
    s.click("h", order: order, command: true, shift: false)
    check(s.selection == ["f", "h"], "⌘-click adds, keeping the tile you were on: \(s.selection)")
    s.click("f", order: order, command: true, shift: false)
    check(s.selection == ["h"], "⌘-click again takes it out: \(s.selection)")
    s = at("c")
    s.click("g", order: order, command: false, shift: true)
    check(s.selection == ["c", "d", "e", "f", "g"], "⇧-click: the run: \(s.selection)")
}

scenario("dragging a tile") {
    var s = at("b", marks: ["a", "c"])
    s.dragStarts(on: "c")
    check(s.selection == ["a", "c"], "from a marked tile: all the marks go")
    s.dragStarts(on: "k")
    check(s.selection == ["k"], "from another tile: that one alone")
}

scenario("the selection set from outside") {
    var s = at("b", marks: ["a", "c"])
    s.adopt(["g"], order: order)
    check(s.cursor == "g" && s.marks.isEmpty, "one file (a new folder, a reveal): the cursor there")
    s.adopt(Set(order), order: order)
    check(s.selection == Set(order) && s.cursor == "g", "⌘A: all marked, the cursor stays")
    s = at("k")
    s.adopt(["b", "d"], order: order)
    check(s.marks == ["b", "d"] && s.cursor == "b", "the cursor moves to the first of them")
    let before = at("e", marks: ["e", "f"])
    var same = before
    same.adopt(["e", "f"], order: order)
    check(same == before, "its own selection coming back changes nothing")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
