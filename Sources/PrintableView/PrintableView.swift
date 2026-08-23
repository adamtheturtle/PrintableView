//
//  PrintableView.swift
//  PrintableView
//

#if os(macOS)
    import AppKit
    import PDFKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
    import PDFKit
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
    /// The rendered view reported a size that cannot be paginated safely.
    case invalidContentGeometry(String)
    /// Core Graphics could not create a PDF destination.
    case couldNotCreatePDFContext
    /// SwiftUI did not provide any drawing callback for the rendered view.
    case renderProducedNoPages
    /// A configured resource ceiling cannot be enforced because it is not positive.
    case invalidResourceLimit(String)
    /// Rendering would require more pages than the configured ceiling.
    case pageCountLimitExceeded(pageCount: Int, maximum: Int)
    /// The encoded PDF grew beyond the configured byte ceiling.
    case pdfSizeLimitExceeded(maximumBytes: Int)
    /// The rendered bytes could not be opened as a platform PDF document.
    case couldNotOpenRenderedPDF
    /// The platform could not create an operation for the rendered document.
    case couldNotCreatePrintOperation
    /// The platform refused to present its print UI.
    case couldNotPresentPrintPanel
    /// Printing failed after the user accepted the platform print UI.
    case printOperationFailed(String?)

    public var errorDescription: String? {
        switch self {
        case let .invalidPageGeometry(reason):
            "Invalid print page geometry: \(reason)"
        case let .invalidContentGeometry(reason):
            "Invalid rendered content geometry: \(reason)"
        case .couldNotCreatePDFContext:
            "The PDF drawing context could not be created."
        case .renderProducedNoPages:
            "The view renderer did not produce any PDF pages."
        case let .invalidResourceLimit(reason):
            "Invalid print resource limit: \(reason)"
        case let .pageCountLimitExceeded(pageCount, maximum):
            "The document requires \(pageCount) pages, exceeding the configured maximum of \(maximum)."
        case let .pdfSizeLimitExceeded(maximumBytes):
            "The encoded PDF exceeds the configured maximum of \(maximumBytes) bytes."
        case .couldNotOpenRenderedPDF:
            "The rendered PDF could not be opened for printing."
        case .couldNotCreatePrintOperation:
            "A print operation could not be created for the rendered PDF."
        case .couldNotPresentPrintPanel:
            "The platform print panel could not be presented."
        case let .printOperationFailed(reason):
            if let reason, !reason.isEmpty {
                "The print operation failed: \(reason)"
            } else {
                "The print operation failed."
            }
        }
    }
}

/// The user-visible outcome after the platform print UI was presented.
public enum PrintPresentationOutcome: Equatable, Sendable {
    /// The platform reported that printing completed.
    case completed
    /// The user cancelled from the platform print UI.
    case cancelled
}

/// A single-line text footer drawn within a bounded area on every PDF page.
///
/// Footer text is clipped to the page's printable width and the configured height. The
/// formatter receives one-based page numbers after pagination is complete.
public struct PrintFooter {
    /// The height reserved below document content, in points.
    public var height: CGFloat
    /// The greatest UTF-8 byte count passed from the formatter to Core Text per page.
    public var maximumTextBytes: Int

    let text: (_ page: Int, _ pageCount: Int) -> String

    /// Creates a page footer.
    ///
    /// - Parameters:
    ///   - height: Space reserved for the footer, in points.
    ///   - text: A formatter receiving the current one-based page number and total pages.
    public init(
        height: CGFloat = 18,
        maximumTextBytes: Int = 4096,
        text: @escaping (_ page: Int, _ pageCount: Int) -> String
    ) {
        self.height = height
        self.maximumTextBytes = maximumTextBytes
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

    /// Creates a source-attribution footer from a URL.
    ///
    /// Credentials embedded in the URL are omitted. `file://` URLs contribute only the
    /// last path component so full local filesystem paths are not printed.
    public static func attribution(sourceURL: URL, height: CGFloat = 18) -> PrintFooter {
        attribution(source: sanitizedAttributionSource(sourceURL), height: height)
    }

    func formattedText(page: Int, pageCount: Int) -> String {
        let limit = maximumTextBytes
        guard limit > 0 else { return "" }
        var result = ""
        var byteCount = 0
        var lastWasSeparator = false
        // Truncate on extended grapheme cluster boundaries so combining marks and
        // multi-scalar emoji are not split mid-character.
        for character in text(page, pageCount) {
            let characterString = String(character)
            let isSeparator = characterString.unicodeScalars.allSatisfy { scalar in
                let category = scalar.properties.generalCategory
                return category == .control || category == .lineSeparator
                    || category == .paragraphSeparator
            }
            if isSeparator {
                guard !lastWasSeparator else { continue }
                guard byteCount + 1 <= limit else { break }
                result.append(" ")
                byteCount += 1
                lastWasSeparator = true
            } else {
                let bytes = characterString.utf8.count
                guard byteCount + bytes <= limit else { break }
                result.append(character)
                byteCount += bytes
                lastWasSeparator = false
            }
        }
        return result
    }
}

/// Returns a footer-safe display string for `url`, without credentials or full file paths.
func sanitizedAttributionSource(_ url: URL) -> String {
    if url.isFileURL {
        let name = url.lastPathComponent
        return name.isEmpty ? "file" : name
    }

    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.absoluteString
    }
    components.user = nil
    components.password = nil
    return components.string ?? url.absoluteString
}

/// Layout and presentation options for a printable SwiftUI document.
public struct PrintConfiguration {
    /// The paper size in points. Pass `nil` to use US Letter (612 × 792 pt).
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
    /// The greatest number of pages a single render may emit.
    public var maximumPageCount: Int
    /// The greatest encoded PDF size a single render may return, in bytes.
    public var maximumPDFBytes: Int

    /// Creates print configuration values.
    public init(
        pageSize: CGSize? = nil,
        margins: EdgeInsets = EdgeInsets(top: 36, leading: 36, bottom: 36, trailing: 36),
        footer: PrintFooter? = nil,
        jobTitle: String = "Document",
        colorScheme: ColorScheme = .light,
        background: Color = .white,
        maximumPageCount: Int = 1_000,
        maximumPDFBytes: Int = 100 * 1_024 * 1_024
    ) {
        self.pageSize = pageSize
        self.margins = margins
        self.footer = footer
        self.jobTitle = jobTitle
        self.colorScheme = colorScheme
        self.background = background
        self.maximumPageCount = maximumPageCount
        self.maximumPDFBytes = maximumPDFBytes
    }
}

/// Renders a SwiftUI view to deterministic, paginated vector PDF data.
///
/// Content is laid out at the printable width and divided into vertical page-height bands.
///
/// ## Platform view limitations
///
/// `ImageRenderer` rasterizes SwiftUI into PDF vector paths. Views backed by native
/// platform frameworks—`WKWebView`, `MKMapView`, `AVPlayerViewController`, Metal-backed
/// content, and other layer-hosted UI—often draw as **blank rectangles** with no error.
/// Pre-render such content to an `Image` or pure SwiftUI, or verify output before printing.
///
/// - Parameter content: Pure SwiftUI content to paginate.
/// - Parameter configuration: Page geometry, appearance, and resource limits.
/// - Returns: Paginated PDF bytes suitable for printing or saving.
/// - Throws: ``PrintDocumentError`` when geometry, limits, or encoding fail.
@MainActor
public func renderPDF(
    _ content: some View,
    configuration: PrintConfiguration = PrintConfiguration()
) throws -> Data {
    try Task.checkCancellation()
    let pageSize = configuration.pageSize ?? defaultPaperSize()
    let layout = try validatedLayout(configuration: configuration, pageSize: pageSize)

    let document = content
        .frame(width: layout.contentWidth, alignment: .leading)
        .environment(\.colorScheme, configuration.colorScheme)
    let renderer = ImageRenderer(content: document)
    renderer.scale = 1

    return try renderPDFData(
        configuration: configuration,
        pageSize: pageSize,
        layout: layout
    ) { body in
        renderer.render(renderer: body)
    }
}

typealias PDFRenderBody = (_ contentSize: CGSize, _ renderInContext: (CGContext) -> Void) -> Void

@MainActor
func renderPDFData(
    configuration: PrintConfiguration,
    pageSize: CGSize,
    layout: ValidatedLayout,
    performRender: (_ body: @escaping PDFRenderBody) -> Void
) throws -> Data {
    guard configuration.maximumPageCount > 0 else {
        throw PrintDocumentError.invalidResourceLimit("maximumPageCount must be greater than zero")
    }
    guard configuration.maximumPDFBytes > 0 else {
        throw PrintDocumentError.invalidResourceLimit("maximumPDFBytes must be greater than zero")
    }
    if let footer = configuration.footer {
        guard footer.height > 0 else {
            throw PrintDocumentError.invalidPageGeometry(
                "footer height must be greater than zero when a footer is configured"
            )
        }
        guard footer.maximumTextBytes > 0 else {
            throw PrintDocumentError.invalidResourceLimit(
                "maximumTextBytes must be greater than zero"
            )
        }
    }

    let pdfData = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    guard
        let consumer = CGDataConsumer(data: pdfData as CFMutableData),
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        throw PrintDocumentError.couldNotCreatePDFContext
    }

    var renderingError: PrintDocumentError?
    var emittedPageCount = 0
    let backgroundColor = resolvedCGColor(configuration.background, colorScheme: configuration.colorScheme)
    performRender { contentSize, renderInContext in
        let pageCount: Int
        do {
            pageCount = try validatedPageCount(
                contentSize: contentSize,
                contentHeight: layout.contentHeight
            )
        } catch let error as PrintDocumentError {
            renderingError = error
            return
        } catch {
            assertionFailure("validatedPageCount threw an undocumented error: \(error)")
            return
        }
        guard pageCount <= configuration.maximumPageCount else {
            renderingError = .pageCountLimitExceeded(
                pageCount: pageCount,
                maximum: configuration.maximumPageCount
            )
            return
        }
        for pageIndex in 0 ..< pageCount {
            context.beginPDFPage(nil)

            // Fill the full media box so margins share the configured background
            // instead of remaining device-default black (#27, #28, #66).
            context.saveGState()
            context.setFillColor(backgroundColor)
            context.fill(CGRect(origin: .zero, size: pageSize))
            context.restoreGState()

            context.saveGState()
            context.clip(to: layout.contentBounds)
            let yOffset = pageSize.height - configuration.margins.top - contentSize.height
                + CGFloat(pageIndex) * layout.contentHeight
            context.translateBy(x: configuration.margins.leading, y: yOffset)
            renderInContext(context)
            context.restoreGState()

            if let footer = configuration.footer {
                drawFooter(
                    footer.formattedText(page: pageIndex + 1, pageCount: pageCount),
                    context: context,
                    bounds: layout.footerBounds
                )
            }
            context.endPDFPage()
            emittedPageCount += 1
            // Fail fast while encoding; final size is re-checked after `closePDF`
            // because the trailer can still grow the byte count (#65).
            if pdfData.length > configuration.maximumPDFBytes {
                renderingError = .pdfSizeLimitExceeded(maximumBytes: configuration.maximumPDFBytes)
                break
            }
        }
    }
    context.closePDF()
    // Prefer the post-finalization size check so trailer growth cannot slip past
    // the mid-encode snapshots above.
    guard pdfData.length <= configuration.maximumPDFBytes else {
        throw PrintDocumentError.pdfSizeLimitExceeded(maximumBytes: configuration.maximumPDFBytes)
    }
    if let renderingError {
        throw renderingError
    }
    guard emittedPageCount > 0 else {
        throw PrintDocumentError.renderProducedNoPages
    }
    return pdfData as Data
}

func validatedPageCount(
    contentSize: CGSize,
    contentHeight: CGFloat
) throws(PrintDocumentError) -> Int {
    guard contentSize.width.isFinite, contentSize.height.isFinite else {
        throw .invalidContentGeometry("width and height must be finite")
    }
    guard contentSize.width > 0 else {
        throw .invalidContentGeometry("width must be greater than zero")
    }
    guard contentSize.height > 0 else {
        throw .invalidContentGeometry("height must be greater than zero")
    }

    let rounded = (contentSize.height / contentHeight).rounded(.up)
    // `CGFloat(Int.max)` rounds to 2^63 on 64-bit platforms, which is one past
    // the largest valid Int. A strict comparison keeps the conversion below
    // that rounded boundary and therefore nontrapping.
    guard rounded.isFinite, rounded < CGFloat(Int.max) else {
        throw .invalidContentGeometry("height exceeds the supported page-count range")
    }
    return max(1, Int(rounded))
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
) async throws -> PrintPresentationOutcome {
    try await printDocument(
        configuration: configuration,
        content: content,
        presenter: livePrintPanelPresenter
    )
}

enum PrintPresentationResult: Equatable {
    case completed
    case cancelled
    case invalidPDF
    case operationUnavailable
    case presentationRejected
    case failed(String?)
}

typealias PrintPanelPresenter = @MainActor (
    _ pdfData: Data,
    _ pageSize: CGSize,
    _ jobTitle: String
) async -> PrintPresentationResult

@MainActor
func printDocument<Content: View>(
    configuration: PrintConfiguration,
    @ViewBuilder content: () -> Content,
    presenter: PrintPanelPresenter
) async throws -> PrintPresentationOutcome {
    let trimmedTitle = configuration.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
        throw PrintDocumentError.invalidResourceLimit("jobTitle must not be empty")
    }
    var configuration = configuration
    configuration.jobTitle = trimmedTitle
    let data = try renderPDF(configuration: configuration, content: content)
    let result = await presenter(
        data,
        configuration.pageSize ?? defaultPaperSize(),
        configuration.jobTitle
    )
    return try presentationOutcome(for: result)
}

private func presentationOutcome(
    for result: PrintPresentationResult
) throws -> PrintPresentationOutcome {
    switch result {
    case .completed:
        .completed
    case .cancelled:
        .cancelled
    case .invalidPDF:
        throw PrintDocumentError.couldNotOpenRenderedPDF
    case .operationUnavailable:
        throw PrintDocumentError.couldNotCreatePrintOperation
    case .presentationRejected:
        throw PrintDocumentError.couldNotPresentPrintPanel
    case let .failed(reason):
        throw PrintDocumentError.printOperationFailed(reason)
    }
}

/// Renders `content`, presents the platform print UI, and reports its final outcome.
@MainActor
public func printDocument(
    _ content: some View,
    jobTitle: String,
    pageSize: CGSize? = nil,
    margins: CGFloat = 36
) async throws -> PrintPresentationOutcome {
    try await printDocument(
        configuration: PrintConfiguration(
            pageSize: pageSize,
            margins: EdgeInsets(top: margins, leading: margins, bottom: margins, trailing: margins),
            jobTitle: jobTitle
        )
    ) {
        content
    }
}

/// Renders `content`, presents the platform print panel, and reports rendering or presentation failures.
///
/// Returns a structured task the caller can retain or cancel. The task completes after
/// presentation finishes or a render error is reported.
@discardableResult
@MainActor
public func printDocument(
    _ content: some View,
    jobTitle: String,
    pageSize: CGSize? = nil,
    margins: CGFloat = 36,
    onError: @escaping @MainActor (PrintDocumentError) -> Void
) -> Task<Void, Never> {
    let configuration = PrintConfiguration(
        pageSize: pageSize,
        margins: EdgeInsets(top: margins, leading: margins, bottom: margins, trailing: margins),
        jobTitle: jobTitle
    )
    return Task { @MainActor in
        do {
            let data = try renderPDF(content, configuration: configuration)
            let result = await livePrintPanelPresenter(
                pdfData: data,
                pageSize: pageSize ?? defaultPaperSize(),
                jobTitle: jobTitle
            )
            do {
                _ = try presentationOutcome(for: result)
            } catch let error as PrintDocumentError {
                onError(error)
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("print presentation threw an undocumented error: \(error)")
            }
        } catch let error as PrintDocumentError {
            onError(error)
        } catch is CancellationError {
            return
        } catch {
            assertionFailure("renderPDF threw an undocumented error: \(error)")
        }
    }
}

/// The original package-internal PDF entry point, retained for source and test compatibility.
@MainActor
func makeDocumentPDFData(
    _ content: some View,
    pageSize: CGSize,
    margins: CGFloat
) throws -> Data {
    try renderPDF(
        content,
        configuration: PrintConfiguration(
            pageSize: pageSize,
            margins: EdgeInsets(top: margins, leading: margins, bottom: margins, trailing: margins)
        )
    )
}

struct ValidatedLayout {
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let contentBounds: CGRect
    let footerBounds: CGRect
}

func validatedLayout(
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
    let font = footerFont(size: fontSize)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
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

private func footerFont(size: CGFloat) -> CTFont {
    #if os(macOS)
        let platformFont = NSFont.systemFont(ofSize: size)
    #else
        let platformFont = UIFont.systemFont(ofSize: size)
    #endif
    return CTFontCreateWithName(platformFont.fontName as CFString, size, nil)
}

@MainActor
private func resolvedCGColor(_ color: Color, colorScheme: ColorScheme) -> CGColor {
    #if os(macOS)
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        guard let appearance = NSAppearance(named: appearanceName) else {
            return NSColor(color).cgColor
        }
        var result = NSColor(color).cgColor
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).cgColor
        }
        return result
    #elseif os(iOS) || os(tvOS) || os(visionOS)
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        return UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).cgColor
    #else
        return CGColor(gray: colorScheme == .dark ? 0 : 1, alpha: 1)
    #endif
}

@MainActor
private func defaultPaperSize() -> CGSize {
    // Always US Letter so renders are deterministic across machines and locales
    // when `pageSize` is omitted (#47). Pass an explicit `pageSize` for A4 or
    // other stock.
    usLetter
}

private let usLetter = CGSize(width: 612, height: 792)

/// Returns whether every page in `document` has a positive media box matching `expectedPageSize`.
func validatedRenderedPDF(_ document: PDFDocument, expectedPageSize: CGSize) -> Bool {
    guard document.pageCount > 0 else { return false }
    for index in 0 ..< document.pageCount {
        guard let page = document.page(at: index) else { return false }
        let mediaBox = page.bounds(for: .mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return false }
        guard abs(mediaBox.width - expectedPageSize.width) <= 1,
              abs(mediaBox.height - expectedPageSize.height) <= 1 else {
            return false
        }
    }
    return true
}

#if os(macOS)
    @MainActor
    private func livePrintPanelPresenter(
        pdfData: Data,
        pageSize: CGSize,
        jobTitle: String
    ) async -> PrintPresentationResult {
        guard let document = PDFDocument(data: pdfData) else { return .invalidPDF }
        guard validatedRenderedPDF(document, expectedPageSize: pageSize) else { return .invalidPDF }
        let info = NSPrintInfo()
        info.paperSize = pageSize
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        // Clip rather than fit so pre-paginated PDF pages are not rescaled (#41).
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleNone,
                                                       autoRotate: false) else {
            return .operationUnavailable
        }
        operation.jobTitle = jobTitle
        switch operation.printPanel.runModal(with: info) {
        case NSApplication.ModalResponse.OK.rawValue:
            break
        case NSApplication.ModalResponse.cancel.rawValue:
            return .cancelled
        default:
            return .presentationRejected
        }
        operation.showsPrintPanel = false
        if operation.run() {
            return .completed
        }
        return .failed("The print operation did not complete successfully.")
    }
#elseif os(iOS)
    @MainActor
    private final class PrintCompletionGate {
        private var continuation: CheckedContinuation<PrintPresentationResult, Never>?
        private var finished = false
        private var timeoutTask: Task<Void, Never>?

        func install(_ continuation: CheckedContinuation<PrintPresentationResult, Never>) {
            self.continuation = continuation
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(600))
                finish(with: .failed("The print UI did not report a result."))
            }
        }

        func finish(with result: PrintPresentationResult) {
            guard !finished else { return }
            finished = true
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    @MainActor
    private func livePrintPanelPresenter(
        pdfData: Data,
        pageSize: CGSize,
        jobTitle: String
    ) async -> PrintPresentationResult {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = jobTitle
        info.outputType = .general
        info.paperRect = CGRect(origin: .zero, size: pageSize)
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = pdfData
        let gate = PrintCompletionGate()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let didPresent = controller.present(animated: true) { _, completed, error in
                let result: PrintPresentationResult
                if let error {
                    result = .failed(error.localizedDescription)
                } else {
                    result = completed ? .completed : .cancelled
                }
                Task { @MainActor in
                    gate.finish(with: result)
                }
            }
            if !didPresent {
                gate.finish(with: .presentationRejected)
            }
        }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
