//
//  PrintableView.swift
//  PrintableView
//

#if os(macOS)
    import AppKit
    import PDFKit
#elseif os(iOS)
    import UIKit
#endif
import CoreGraphics
import CoreText
import Foundation
import SwiftUI

/// An error encountered while laying out or encoding a printable document.
public enum PrintDocumentError: Error, Equatable, LocalizedError {
    /// The page size, margins, or footer do not describe a usable page.
    case invalidPageGeometry(String)
    /// Core Graphics could not create a PDF destination.
    case couldNotCreatePDFContext

    public var errorDescription: String? {
        switch self {
        case let .invalidPageGeometry(reason):
            "Invalid print page geometry: \(reason)"
        case .couldNotCreatePDFContext:
            "The PDF drawing context could not be created."
        }
    }
}

/// A single-line text footer drawn within a bounded area on every PDF page.
///
/// Footer text is clipped to the page's printable width and the configured height. The
/// formatter receives one-based page numbers after pagination is complete.
public struct PrintFooter {
    /// The height reserved below document content, in points.
    public var height: CGFloat

    let text: (_ page: Int, _ pageCount: Int) -> String

    /// Creates a page footer.
    ///
    /// - Parameters:
    ///   - height: Space reserved for the footer, in points.
    ///   - text: A formatter receiving the current one-based page number and total pages.
    public init(
        height: CGFloat = 18,
        text: @escaping (_ page: Int, _ pageCount: Int) -> String
    ) {
        self.height = height
        self.text = text
    }

    /// Creates a footer containing a source attribution and page numbering.
    ///
    /// The result has the form `source • Page 2 of 5`. The drawing bounds safely clip a
    /// source that is too long to fit; callers do not need to truncate it themselves.
    public static func attribution(source: String, height: CGFloat = 18) -> PrintFooter {
        PrintFooter(height: height) { page, pageCount in
            "\(source) • Page \(page) of \(pageCount)"
        }
    }

    /// Creates a source-attribution footer from a URL's absolute string.
    public static func attribution(sourceURL: URL, height: CGFloat = 18) -> PrintFooter {
        attribution(source: sourceURL.absoluteString, height: height)
    }
}

/// Layout and presentation options for a printable SwiftUI document.
public struct PrintConfiguration {
    /// The paper size in points. Pass `nil` to use the platform default.
    public var pageSize: CGSize?
    /// The inset from each paper edge, in points.
    public var margins: EdgeInsets
    /// An optional single-line footer reserved beneath the document content.
    public var footer: PrintFooter?
    /// The title shown by the system print panel and print queue.
    public var jobTitle: String
    /// The appearance used to resolve adaptive colors in the rendered view.
    public var colorScheme: ColorScheme
    /// The background drawn behind the document content.
    public var background: Color

    /// Creates print configuration values.
    public init(
        pageSize: CGSize? = nil,
        margins: EdgeInsets = EdgeInsets(top: 36, leading: 36, bottom: 36, trailing: 36),
        footer: PrintFooter? = nil,
        jobTitle: String = "Document",
        colorScheme: ColorScheme = .light,
        background: Color = .white
    ) {
        self.pageSize = pageSize
        self.margins = margins
        self.footer = footer
        self.jobTitle = jobTitle
        self.colorScheme = colorScheme
        self.background = background
    }
}

/// Renders a SwiftUI view to deterministic, paginated vector PDF data.
///
/// Content is laid out at the printable width and divided into vertical page-height bands.
/// Views backed by native platform frameworks, such as web views, maps, video, or Metal,
/// may render as blank rectangles due to `ImageRenderer` limitations.
@MainActor
public func renderPDF(
    _ content: some View,
    configuration: PrintConfiguration = PrintConfiguration()
) throws -> Data {
    let pageSize = configuration.pageSize ?? defaultPaperSize()
    let layout = try validatedLayout(configuration: configuration, pageSize: pageSize)

    let document = content
        .frame(width: layout.contentWidth, alignment: .leading)
        .environment(\.colorScheme, configuration.colorScheme)
        .background(configuration.background)
    let renderer = ImageRenderer(content: document)
    renderer.scale = 1

    let pdfData = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    guard
        let consumer = CGDataConsumer(data: pdfData as CFMutableData),
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        throw PrintDocumentError.couldNotCreatePDFContext
    }

    renderer.render { contentSize, renderInContext in
        let pageCount = max(1, Int((contentSize.height / layout.contentHeight).rounded(.up)))
        for pageIndex in 0 ..< pageCount {
            context.beginPDFPage(nil)

            context.saveGState()
            context.clip(to: layout.contentBounds)
            let yOffset = pageSize.height - configuration.margins.top - contentSize.height
                + CGFloat(pageIndex) * layout.contentHeight
            context.translateBy(x: configuration.margins.leading, y: yOffset)
            renderInContext(context)
            context.restoreGState()

            if let footer = configuration.footer {
                drawFooter(
                    footer.text(pageIndex + 1, pageCount),
                    context: context,
                    bounds: layout.footerBounds
                )
            }
            context.endPDFPage()
        }
    }
    context.closePDF()
    return pdfData as Data
}

/// Builds and renders a SwiftUI view to paginated PDF data.
@MainActor
public func renderPDF<Content: View>(
    configuration: PrintConfiguration = PrintConfiguration(),
    @ViewBuilder content: () -> Content
) throws -> Data {
    try renderPDF(content(), configuration: configuration)
}

/// Renders a configured SwiftUI document and presents the platform print UI.
@MainActor
public func printDocument<Content: View>(
    configuration: PrintConfiguration,
    @ViewBuilder content: () -> Content
) throws {
    let data = try renderPDF(configuration: configuration, content: content)
    presentPrintPanel(
        pdfData: data,
        pageSize: configuration.pageSize ?? defaultPaperSize(),
        jobTitle: configuration.jobTitle
    )
}

/// Renders `content` and presents the platform's standard print panel.
///
/// This source-compatible convenience API uses a uniform margin. Use
/// ``printDocument(configuration:content:)`` or the `onError` overload when failure must
/// be observable. This compatibility overload intentionally ignores rendering failures.
@available(*, deprecated, message: "Use the throwing configuration overload or the onError overload")
@MainActor
public func printDocument(
    _ content: some View,
    jobTitle: String,
    pageSize: CGSize? = nil,
    margins: CGFloat = 36
) {
    printDocument(
        content,
        jobTitle: jobTitle,
        pageSize: pageSize,
        margins: margins,
        onError: { _ in }
    )
}

/// Renders `content`, presents the platform print panel, and reports rendering failures.
@MainActor
public func printDocument(
    _ content: some View,
    jobTitle: String,
    pageSize: CGSize? = nil,
    margins: CGFloat = 36,
    onError: (PrintDocumentError) -> Void
) {
    let configuration = PrintConfiguration(
        pageSize: pageSize,
        margins: EdgeInsets(top: margins, leading: margins, bottom: margins, trailing: margins),
        jobTitle: jobTitle
    )
    do {
        let data = try renderPDF(content, configuration: configuration)
        presentPrintPanel(
            pdfData: data,
            pageSize: pageSize ?? defaultPaperSize(),
            jobTitle: jobTitle
        )
    } catch let error as PrintDocumentError {
        onError(error)
    } catch {
        assertionFailure("renderPDF threw an undocumented error: \(error)")
    }
}

/// The original package-internal PDF entry point, retained for source and test compatibility.
@MainActor
func makeDocumentPDFData(
    _ content: some View,
    pageSize: CGSize,
    margins: CGFloat
) -> Data? {
    try? renderPDF(
        content,
        configuration: PrintConfiguration(
            pageSize: pageSize,
            margins: EdgeInsets(top: margins, leading: margins, bottom: margins, trailing: margins)
        )
    )
}

private struct ValidatedLayout {
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let contentBounds: CGRect
    let footerBounds: CGRect
}

private func validatedLayout(
    configuration: PrintConfiguration,
    pageSize: CGSize
) throws -> ValidatedLayout {
    let margins = configuration.margins
    let footerHeight = configuration.footer?.height ?? 0
    let values = [pageSize.width, pageSize.height, margins.top, margins.leading,
                  margins.bottom, margins.trailing, footerHeight]
    guard values.allSatisfy(\.isFinite) else {
        throw PrintDocumentError.invalidPageGeometry("all dimensions must be finite")
    }
    guard pageSize.width > 0, pageSize.height > 0 else {
        throw PrintDocumentError.invalidPageGeometry("page width and height must be greater than zero")
    }
    guard margins.top >= 0, margins.leading >= 0, margins.bottom >= 0, margins.trailing >= 0 else {
        throw PrintDocumentError.invalidPageGeometry("margins cannot be negative")
    }
    guard footerHeight >= 0 else {
        throw PrintDocumentError.invalidPageGeometry("footer height cannot be negative")
    }

    let contentWidth = pageSize.width - margins.leading - margins.trailing
    let contentHeight = pageSize.height - margins.top - margins.bottom - footerHeight
    guard contentWidth > 0 else {
        throw PrintDocumentError.invalidPageGeometry("horizontal margins leave no printable width")
    }
    guard contentHeight > 0 else {
        throw PrintDocumentError.invalidPageGeometry("margins and footer leave no printable height")
    }

    return ValidatedLayout(
        contentWidth: contentWidth,
        contentHeight: contentHeight,
        contentBounds: CGRect(
            x: margins.leading,
            y: margins.bottom + footerHeight,
            width: contentWidth,
            height: contentHeight
        ),
        footerBounds: CGRect(
            x: margins.leading,
            y: margins.bottom,
            width: contentWidth,
            height: footerHeight
        )
    )
}

private func drawFooter(_ text: String, context: CGContext, bounds: CGRect) {
    guard bounds.width > 0, bounds.height > 0 else { return }
    let fontSize = min(8, max(1, bounds.height - 4))
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String):
            CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
            CGColor(gray: 0.35, alpha: 1)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.saveGState()
    context.clip(to: bounds)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: bounds.minX, y: bounds.minY + max(1, (bounds.height - fontSize) / 2))
    CTLineDraw(line, context)
    context.restoreGState()
}

@MainActor
private func defaultPaperSize() -> CGSize {
    #if os(macOS)
        let size = NSPrintInfo.shared.paperSize
        return size.width > 0 && size.height > 0 ? size : usLetter
    #else
        return usLetter
    #endif
}

private let usLetter = CGSize(width: 612, height: 792)

#if os(macOS)
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
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleNone,
                                                       autoRotate: false) else { return }
        operation.jobTitle = jobTitle
        operation.run()
    }
#elseif os(iOS)
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

/// A titled block in a printed document.
public struct PrintSection<Content: View>: View {
    private let title: String
    @ViewBuilder private let content: () -> Content

    public init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Monospaced, wrapping text suitable for printed source code.
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
