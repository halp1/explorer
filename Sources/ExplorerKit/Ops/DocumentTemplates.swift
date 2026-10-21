import Foundation
import CArchive

/// Minimal empty documents generated in code (no bundled templates).
public enum DocumentTemplate: String, CaseIterable, Sendable {
    case word = "docx", excel = "xlsx", powerpoint = "pptx", rtf = "rtf", text = "txt"

    public var menuTitle: String {
        switch self {
        case .word: return "New Word Document..."
        case .excel: return "New Excel Document..."
        case .powerpoint: return "New PowerPoint Document..."
        case .rtf: return "New RTF File..."
        case .text: return "New Empty File..."
        }
    }
    public var defaultName: String {
        switch self { case .text: return "Untitled.txt"; default: return "Untitled.\(rawValue)" }
    }

    public func write(to url: URL) throws {
        switch self {
        case .text: try Data().write(to: url, options: .withoutOverwriting)
        case .rtf: try Data(#"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24 }"#.utf8).write(to: url, options: .withoutOverwriting)
        case .word: try OOXML.zip(OOXML.docx, to: url)
        case .excel: try OOXML.zip(OOXML.xlsx, to: url)
        case .powerpoint: try OOXML.zip(OOXML.pptx, to: url)
        }
    }
}

enum OOXML {
    static let ct = "http://schemas.openxmlformats.org/package/2006/content-types"
    static let rel = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let officeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    static let hdr = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static var docx: [(String, String)] {[
        ("[Content_Types].xml", hdr + """
        <Types xmlns="\(ct)"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """),
        ("_rels/.rels", hdr + "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"rId1\" Type=\"\(officeRel)\" Target=\"word/document.xml\"/></Relationships>"),
        ("word/document.xml", hdr + """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p/><w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """),
    ]}

    static var xlsx: [(String, String)] {[
        ("[Content_Types].xml", hdr + """
        <Types xmlns="\(ct)"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """),
        ("_rels/.rels", hdr + "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"rId1\" Type=\"\(officeRel)\" Target=\"xl/workbook.xml\"/></Relationships>"),
        ("xl/workbook.xml", hdr + """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """),
        ("xl/_rels/workbook.xml.rels", hdr + "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
        ("xl/worksheets/sheet1.xml", hdr + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData/></worksheet>"),
    ]}

    static var pptx: [(String, String)] {
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let emptyTree = "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"
        return [
            ("[Content_Types].xml", hdr + """
            <Types xmlns="\(ct)"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/></Types>
            """),
            ("_rels/.rels", hdr + "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"rId1\" Type=\"\(officeRel)\" Target=\"ppt/presentation.xml\"/></Relationships>"),
            ("ppt/presentation.xml", hdr + """
            <p:presentation xmlns:a="\(a)" xmlns:r="\(r)" xmlns:p="\(p)"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
            """),
            ("ppt/_rels/presentation.xml.rels", hdr + """
            <Relationships xmlns="\(rel)"><Relationship Id="rId1" Type="\(r)/slideMaster" Target="slideMasters/slideMaster1.xml"/><Relationship Id="rId2" Type="\(r)/slide" Target="slides/slide1.xml"/><Relationship Id="rId3" Type="\(r)/theme" Target="theme/theme1.xml"/></Relationships>
            """),
            ("ppt/slideMasters/slideMaster1.xml", hdr + """
            <p:sldMaster xmlns:a="\(a)" xmlns:r="\(r)" xmlns:p="\(p)">\(emptyTree)<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
            """),
            ("ppt/slideMasters/_rels/slideMaster1.xml.rels", hdr + """
            <Relationships xmlns="\(rel)"><Relationship Id="rId1" Type="\(r)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="\(r)/theme" Target="../theme/theme1.xml"/></Relationships>
            """),
            ("ppt/slideLayouts/slideLayout1.xml", hdr + "<p:sldLayout xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\" type=\"blank\">\(emptyTree)</p:sldLayout>"),
            ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", hdr + "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"rId1\" Type=\"\(r)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>"),
            ("ppt/slides/slide1.xml", hdr + "<p:sld xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\">\(emptyTree)</p:sld>"),
            ("ppt/slides/_rels/slide1.xml.rels", hdr + "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"rId1\" Type=\"\(r)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/></Relationships>"),
            ("ppt/theme/theme1.xml", hdr + theme(a)),
        ]
    }

    static func theme(_ a: String) -> String {
        func c(_ n: String, _ v: String) -> String { "<a:\(n)><a:srgbClr val=\"\(v)\"/></a:\(n)>" }
        let colors = c("dk1", "000000") + c("lt1", "FFFFFF") + c("dk2", "44546A") + c("lt2", "E7E6E6") + c("accent1", "4472C4") + c("accent2", "ED7D31")
            + c("accent3", "A5A5A5") + c("accent4", "FFC000") + c("accent5", "5B9BD5") + c("accent6", "70AD47") + c("hlink", "0563C1") + c("folHlink", "954F72")
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let ln = "<a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
        return """
        <a:theme xmlns:a="\(a)" name="Office"><a:themeElements><a:clrScheme name="Office">\(colors)</a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(ln)\(ln)\(ln)</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """
    }

    /// Writes (path, text) parts into a zip using libarchive.
    static func zip(_ parts: [(String, String)], to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        guard let w = archive_write_new() else { throw ArchiveError.failed("zip") }
        defer { archive_write_free(w) }
        archive_write_set_format_zip(w)
        guard archive_write_open_filename(w, url.path) == ARCHIVE_OK else { throw ArchiveError.failed("Could not create \(url.lastPathComponent)") }
        for (path, text) in parts {
            let data = Data(text.utf8)
            guard let e = archive_entry_new() else { continue }
            archive_entry_set_pathname_utf8(e, path)
            archive_entry_set_filetype(e, AE_IFREG)
            archive_entry_set_perm(e, 0o644)
            archive_entry_set_size(e, Int64(data.count))
            archive_entry_set_mtime(e, time(nil), 0)
            archive_write_header(w, e)
            _ = data.withUnsafeBytes { archive_write_data(w, $0.baseAddress, data.count) }
            archive_entry_free(e)
        }
        archive_write_close(w)
    }
}
