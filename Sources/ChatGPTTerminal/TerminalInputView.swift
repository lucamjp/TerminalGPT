import AppKit
import Carbon
import UniformTypeIdentifiers

final class TerminalInputView: NSTextView {
    var attachmentsDidChange: (([PendingAttachment]) -> Void)?
    var historyNavigationRequested: ((Int) -> Void)?
    var sendRequested: (() -> Void)?
    private(set) var pendingAttachments: [PendingAttachment] = []

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_UpArrow) {
            historyNavigationRequested?(-1)
            return
        }
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_DownArrow) {
            historyNavigationRequested?(1)
            return
        }
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Return) {
            sendRequested?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if importAttachments(from: board) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canImportAttachments(from: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        importAttachments(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    func clearAll() {
        string = ""
        pendingAttachments.removeAll()
        attachmentsDidChange?(pendingAttachments)
    }

    func setAttachments(_ attachments: [PendingAttachment]) {
        pendingAttachments = attachments
        attachmentsDidChange?(pendingAttachments)
    }

    private func canImportAttachments(from board: NSPasteboard) -> Bool {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("org.webmproject.webp")
        ]
        return board.availableType(from: imageTypes + [.pdf]) != nil ||
            board.canReadObject(forClasses: [NSImage.self, NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    @discardableResult
    private func importAttachments(from board: NSPasteboard) -> Bool {
        var imported: [PendingAttachment] = []

        if let data = board.data(forType: .pdf), let item = pdfAttachment(from: data) {
            imported.append(item)
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("org.webmproject.webp")
        ]
        if let type = board.availableType(from: imageTypes),
           let data = board.data(forType: type),
           let image = NSImage(data: data),
           let item = imageAttachment(from: image) {
            imported.append(item)
        }

        if imported.isEmpty, let objects = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in objects {
                if let item = imageAttachment(from: image) { imported.append(item) }
            }
        }

        if imported.isEmpty, let image = NSImage(pasteboard: board), let item = imageAttachment(from: image) {
            imported.append(item)
        }

        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .pdf) == true,
                   let data = try? Data(contentsOf: url),
                   let item = pdfAttachment(from: data, fileName: url.lastPathComponent) {
                    imported.append(item)
                } else if type?.conforms(to: .image) == true,
                          let image = NSImage(contentsOf: url),
                          let item = imageAttachment(from: image, fileName: url.deletingPathExtension().lastPathComponent + ".png") {
                    imported.append(item)
                }
            }
        }

        var seen = Set<String>()
        imported = imported.filter { attachment in
            let key = "\(attachment.mimeType)|\(attachment.data.count)|\(attachment.data.hashValue)"
            return seen.insert(key).inserted
        }
        guard !imported.isEmpty else { return false }
        pendingAttachments.append(contentsOf: imported)
        attachmentsDidChange?(pendingAttachments)
        return true
    }
}
