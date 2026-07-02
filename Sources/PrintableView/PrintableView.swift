//
//  PrintableView.swift
//  PrintableView
//
//  Print a SwiftUI view to paper (or Save-as-PDF) on macOS and iPadOS. SwiftUI has no
//  print pipeline of its own, so the content is rendered to a paginated *vector* PDF with
//  `ImageRenderer`'s `render(rasterizationScale:renderer:)` closure drawn into a
//  `CGContext` PDF context, and that PDF is handed to the platform print machinery
//  (`PDFDocument.printOperation` on macOS, `UIPrintInteractionController` on iOS).
//
//  Why a vector PDF rather than a rasterized bitmap: text and shapes are emitted as vector
//  drawing operations, so they print crisp at the printer's true resolution, stay
//  selectable/searchable in a saved PDF, produce small files, and avoid the large-bitmap
//  memory spike of rasterizing a long document at 2x. (Bitmap *images* embedded in the
//  content remain raster, as they must.)
//
//  Why render through `ImageRenderer` at all rather than printing a hosted view directly:
//  handing an `NSHostingView` to `NSPrintOperation` yields blank pages, because a
//  layer-backed SwiftUI view's content isn't emitted through the `draw(_:)` path the print
//  system captures. Rendering into a `CGContext` sidesteps that entirely.
//

#if os(macOS)
    import AppKit
    import PDFKit
#else
    import UIKit
#endif
import CoreGraphics
import SwiftUI

/// Renders `content` to a paginated vector PDF and presents the platform's standard print
/// panel (from which the user can print or Save-as-PDF).
///
/// The content is laid out at the page's printable width, pinned to a light color scheme on
/// a white background — paper is white, and adaptive colors would otherwise print as
/// whatever the current appearance happens to be (e.g. white-on-white in dark mode). Content
/// taller than one page is split across pages by vertical position; a single line of content
/// sitting on a page boundary can therefore be divided across the break.
///
/// - Note: Like all `ImageRenderer` output, views backed by native platform frameworks
///   (`MapKit` maps, `WKWebView`, `AVPlayer`, Metal/SceneKit) render as blank rectangles.
///
/// - Parameters:
///   - content: The SwiftUI view to print.
///   - jobTitle: The print job's title, shown in the print panel and print queue.
///   - pageSize: The paper size in points. Defaults to the platform's default paper size.
///   - margins: The uniform page margin in points. Defaults to 36 (half an inch).
@MainActor
public func printDocument(
    _ content: some View,
    jobTitle: String,
    pageSize: CGSize? = nil,
    margins: CGFloat = 36
) {
    let paperSize = pageSize ?? defaultPaperSize()
    guard let pdfData = makeDocumentPDFData(content, pageSize: paperSize, margins: margins) else {
        return
    }
    presentPrintPanel(pdfData: pdfData, pageSize: paperSize, jobTitle: jobTitle)
}

/// Renders `content` to a multi-page vector PDF and returns the encoded document data, or
/// `nil` if a PDF context could not be created.
///
/// Split out from ``printDocument(_:jobTitle:pageSize:margins:)`` so the pagination is
/// testable without presenting UI. The content is constrained to the printable width
/// (`pageSize.width` minus both margins) and its natural height is sliced into page-height
/// bands.
@MainActor
func makeDocumentPDFData(
    _ content: some View,
    pageSize: CGSize,
    margins: CGFloat
) -> Data? {
    let contentWidth = pageSize.width - margins * 2
    let printableHeight = pageSize.height - margins * 2

    let document = content
        .frame(width: contentWidth, alignment: .leading)
        .environment(\.colorScheme, .light)
        .background(Color.white)

    let renderer = ImageRenderer(content: document)
    // Point-for-point vector output; the printer, not us, decides device resolution.
    renderer.scale = 1

    let pdfData = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    guard
        let consumer = CGDataConsumer(data: pdfData as CFMutableData),
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        return nil
    }

    renderer.render { contentSize, renderInContext in
        // `contentSize` is the full laid-out content (contentWidth x total height). The
        // render closure draws the whole thing upright into `context`; we shift and clip it
        // per page to emit one printable band at a time.
        //
        // PDF pages use a bottom-left origin. The content, as drawn, spans y in
        // [0, contentSize.height] with its top edge at the high end. For page `i` we want the
        // band starting `i * printableHeight` down from the content's top to land at the top
        // of the printable box, so we translate the whole content up by that offset and clip
        // to the page's printable rectangle.
        let pageCount = max(1, Int((contentSize.height / printableHeight).rounded(.up)))
        for page in 0 ..< pageCount {
            context.beginPDFPage(nil)
            context.saveGState()
            // Clip in page coordinates (before the translate below applies to drawing).
            context.clip(to: CGRect(x: margins, y: margins, width: contentWidth, height: printableHeight))
            let yOffset = pageSize.height - margins - contentSize.height + CGFloat(page) * printableHeight
            context.translateBy(x: margins, y: yOffset)
            renderInContext(context)
            context.restoreGState()
            context.endPDFPage()
        }
    }
    context.closePDF()

    return pdfData as Data
}

/// The platform's default paper size in points.
@MainActor
private func defaultPaperSize() -> CGSize {
    #if os(macOS)
        // Respects the system/printer default (e.g. A4 vs. US Letter by region).
        let size = NSPrintInfo.shared.paperSize
        return size.width > 0 && size.height > 0 ? size : usLetter
    #else
        return usLetter
    #endif
}

/// US Letter at 72 points per inch (8.5" x 11").
private let usLetter = CGSize(width: 612, height: 792)

#if os(macOS)
    /// Prints `pdfData` through the standard macOS print panel. The PDF already carries
    /// full-page-sized pages with margins baked in, so it prints 1:1 with no extra scaling
    /// or margins.
    @MainActor
    private func presentPrintPanel(pdfData: Data, pageSize: CGSize, jobTitle: String) {
        guard let document = PDFDocument(data: pdfData) else { return }

        let info = NSPrintInfo()
        info.paperSize = pageSize
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .fit

        guard
            let operation = document.printOperation(
                for: info,
                scalingMode: .pageScaleNone,
                autoRotate: false
            )
        else {
            return
        }
        operation.jobTitle = jobTitle
        operation.run()
    }
#else
    /// Prints `pdfData` through the standard iOS/iPadOS print interaction controller. PDF
    /// data is a valid printing item, which UIKit paginates page-per-page on its own.
    @MainActor
    private func presentPrintPanel(pdfData: Data, pageSize _: CGSize, jobTitle: String) {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = jobTitle
        info.outputType = .general

        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = pdfData
        controller.present(animated: true)
    }
#endif

// MARK: - Print layout primitives

/// A titled block in a printed document — a small heading over its content, with space below
/// so sections don't run together across a page.
public struct PrintSection<Content: View>: View {
    private let title: String
    @ViewBuilder private let content: () -> Content

    public init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Code rendered for paper: plain wrapping monospaced text rather than an on-screen
/// syntax-highlighted, horizontally-scrolling view (which wouldn't paginate). Wrapping keeps
/// long lines on the page instead of clipping them.
public struct PrintCode: View {
    private let code: String

    public init(code: String) {
        self.code = code
    }

    public var body: some View {
        Text(code)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.disabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
