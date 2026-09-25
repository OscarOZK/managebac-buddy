// pdftext —— 用系统 PDFKit 把 PDF 提取成纯文本（每页之间用 \f 分隔）
// 编译：swiftc -O -o pdftext pdftext.swift
// 用法：pdftext <file.pdf> [起始页(0-based)] [页数]
import Foundation
import PDFKit

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("usage: pdftext <file.pdf> [from] [count]\n".data(using: .utf8)!)
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
guard let doc = PDFDocument(url: url) else {
    FileHandle.standardError.write("cannot open pdf\n".data(using: .utf8)!)
    exit(3)
}
let from = args.count > 2 ? (Int(args[2]) ?? 0) : 0
let count = args.count > 3 ? (Int(args[3]) ?? doc.pageCount) : doc.pageCount
var out = ""
let end = min(doc.pageCount, from + count)
var i = max(0, from)
while i < end {
    if let p = doc.page(at: i), let s = p.string {
        out += s + "\n\u{000C}\n"
    }
    i += 1
}
FileHandle.standardOutput.write(out.data(using: .utf8)!)
