// pdgrid —— 输出 PDF 指定页每个字符的坐标，供上层重建表格
// 用法：pdgrid <file.pdf> [页号]
// 输出：每行 "索引\tx\ty\t字符"（索引按 UTF-16，与 PDFKit characterBounds 对齐）
import Foundation
import PDFKit

let args = CommandLine.arguments
guard args.count > 1 else { exit(2) }
let url = URL(fileURLWithPath: args[1])
guard let doc = PDFDocument(url: url) else { exit(3) }
let pageNo = args.count > 2 ? (Int(args[2]) ?? 0) : 0
guard pageNo < doc.pageCount, let page = doc.page(at: pageNo) else { exit(4) }

// 关键：characterBounds 的索引是 UTF-16 码元，必须按 utf16 遍历，
// 用 Swift 的 Character 遍历会因组合字符/代理对而整体错位。
let u16 = Array((page.string ?? "").utf16)
let n = min(u16.count, page.numberOfCharacters)
var buf = ""
for i in 0 ..< n {
    let b = page.characterBounds(at: i)
    let scalar = UnicodeScalar(u16[i]) ?? "?"
    let ch: String
    switch scalar {
    case "\n": ch = "\\n"
    case "\r": ch = "\\r"
    case "\t": ch = "\\t"
    default:   ch = String(scalar)
    }
    if b.isNull || b.isEmpty {
        buf += "\(i)\t-\t-\t\(ch)\n"
    } else {
        buf += "\(i)\t\(Int(b.minX))\t\(Int(b.minY))\t\(ch)\n"
    }
    if buf.utf8.count > 200_000 {
        FileHandle.standardOutput.write(buf.data(using: .utf8)!); buf = ""
    }
}
FileHandle.standardOutput.write(buf.data(using: .utf8)!)
