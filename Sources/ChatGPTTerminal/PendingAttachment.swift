import AppKit
import PDFKit

struct PendingAttachment {
    let data: Data
    let pasteboardType: NSPasteboard.PasteboardType
    let preview: NSImage
    let fileName: String
    let mimeType: String
}

func imageAttachment(from image: NSImage, fileName: String = "clipboard-image.png") -> PendingAttachment? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
    return PendingAttachment(data: png, pasteboardType: .png, preview: image, fileName: fileName, mimeType: "image/png")
}

func pdfAttachment(from data: Data, fileName: String = "clipboard-document.pdf") -> PendingAttachment? {
    guard let document = PDFDocument(data: data), let firstPage = document.page(at: 0) else { return nil }
    let preview = firstPage.thumbnail(of: NSSize(width: 180, height: 180), for: .cropBox)
    return PendingAttachment(data: data, pasteboardType: .pdf, preview: preview, fileName: fileName, mimeType: "application/pdf")
}
