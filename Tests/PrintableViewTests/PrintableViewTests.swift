//
//  PrintableViewTests.swift
//  PrintableViewTests
//
//  Exercises the pagination and PDF-generation logic without presenting a print panel.
//  The actual print/Save-as-PDF panel is UI and platform-driven, so it isn't unit-tested;
//  what is tested is that `makeDocumentPDFData` produces a valid PDF, sizes its pages to the
//  requested paper, and splits tall content across the expected number of pages.
//

import CoreGraphics
import PDFKit
import SwiftUI
import Testing
@testable import PrintableView

@MainActor
struct PrintableViewTests {
    private let letter = CGSize(width: 612, height: 792)
    private let margins: CGFloat = 36

    /// Parses `data` as a PDF and returns its page count, or `nil` if it isn't a valid PDF.
    private func pageCount(_ data: Data) -> Int? {
        guard
            let provider = CGDataProvider(data: data as CFData),
            let document = CGPDFDocument(provider)
        else {
            return nil
        }
        return document.numberOfPages
    }

    /// Returns the media-box size of `page` (1-indexed) in `data`.
    private func mediaBoxSize(_ data: Data, page: Int) -> CGSize? {
        guard
            let provider = CGDataProvider(data: data as CFData),
            let document = CGPDFDocument(provider),
            let pdfPage = document.page(at: page)
        else {
            return nil
        }
        return pdfPage.getBoxRect(.mediaBox).size
    }

    private func pageText(_ data: Data, page: Int) -> String? {
        PDFDocument(data: data)?.page(at: page - 1)?.string
    }

    @Test func `short content produces a single page`() {
        let data = makeDocumentPDFData(Text("Hello, paper."), pageSize: letter, margins: margins)
        #expect(data != nil)
        #expect(pageCount(data!) == 1)
    }

    @Test func `content sizes the page to the requested paper`() {
        let data = makeDocumentPDFData(Text("Hello, paper."), pageSize: letter, margins: margins)
        let size = mediaBoxSize(data!, page: 1)
        #expect(size?.width == letter.width)
        #expect(size?.height == letter.height)
    }

    @Test func `tall content is split across multiple pages`() {
        // Printable height is 792 - 72 = 720pt. A fixed 2000pt-tall view must span 3 pages.
        let tall = Color.black.frame(height: 2000)
        let data = makeDocumentPDFData(tall, pageSize: letter, margins: margins)
        #expect(data != nil)
        #expect(pageCount(data!) == 3)
    }

    @Test func `public renderer creates one page`() throws {
        let data = try renderPDF(
            Text("Public API"),
            configuration: PrintConfiguration(pageSize: letter)
        )
        #expect(pageCount(data) == 1)
    }

    @Test func `public renderer creates multiple pages`() throws {
        let data = try renderPDF(
            Color.black.frame(height: 2000),
            configuration: PrintConfiguration(pageSize: letter)
        )
        #expect(pageCount(data) == 3)
    }

    @Test func `footer receives current and total page counts`() throws {
        let configuration = PrintConfiguration(
            pageSize: letter,
            footer: PrintFooter { page, pageCount in
                "Source example.test • Page \(page) of \(pageCount)"
            }
        )
        let data = try renderPDF(Color.black.frame(height: 1500), configuration: configuration)

        #expect(pageCount(data) == 3)
        #expect(pageText(data, page: 1)?.contains("Page 1 of 3") == true)
        #expect(pageText(data, page: 2)?.contains("Page 2 of 3") == true)
        #expect(pageText(data, page: 3)?.contains("Page 3 of 3") == true)
    }

    @Test func `footer formatting normalizes line breaks and controls`() {
        let footer = PrintFooter { _, _ in "Source\r\nSecond\tline\u{2028}last" }

        #expect(footer.formattedText(page: 1, pageCount: 1) == "Source Second line last")
    }

    @Test func `attribution footer includes source and page count`() throws {
        let configuration = PrintConfiguration(
            pageSize: letter,
            footer: .attribution(source: "https://example.com/resource")
        )
        let data = try renderPDF(Text("Document"), configuration: configuration)
        let text = pageText(data, page: 1)

        #expect(text?.contains("https://example.com/resource") == true)
        #expect(text?.contains("Page 1 of 1") == true)
    }

    @Test func `long footer remains bounded to its page`() throws {
        let longSource = "https://example.com/" + String(repeating: "very-long-segment/", count: 200)
        let configuration = PrintConfiguration(
            pageSize: CGSize(width: 240, height: 300),
            footer: .attribution(source: longSource)
        )
        let data = try renderPDF(Text("Document"), configuration: configuration)

        #expect(pageCount(data) == 1)
        #expect(mediaBoxSize(data, page: 1) == configuration.pageSize)
        #expect(pageText(data, page: 1)?.contains("https://example.com/") == true)
    }

    @Test func `invalid geometry throws a meaningful error`() {
        let configuration = PrintConfiguration(
            pageSize: CGSize(width: 100, height: 100),
            margins: EdgeInsets(top: 40, leading: 50, bottom: 40, trailing: 50),
            footer: PrintFooter(height: 30) { _, _ in "Footer" }
        )

        #expect(throws: PrintDocumentError.self) {
            try renderPDF(Text("No room"), configuration: configuration)
        }
    }

    @Test func `negative dimensions are rejected`() {
        let configuration = PrintConfiguration(
            pageSize: letter,
            margins: EdgeInsets(top: -1, leading: 36, bottom: 36, trailing: 36)
        )
        #expect(throws: PrintDocumentError.self) {
            try renderPDF(Text("No room"), configuration: configuration)
        }
    }

    @Test func `larger margins yield more pages for the same content`() {
        let tall = Color.black.frame(height: 2000)
        let thin = makeDocumentPDFData(tall, pageSize: letter, margins: 36)
        let thick = makeDocumentPDFData(tall, pageSize: letter, margins: 144)
        // Bigger margins shrink the printable band, so the same content needs more pages.
        #expect(pageCount(thick!)! > pageCount(thin!)!)
    }

    @Test func `print section renders to a non-empty raster`() {
        let renderer = ImageRenderer(
            content: PrintSection(title: "Transcript") {
                PrintCode(code: "print(\"hello\")")
            }
            .frame(width: 400)
        )
        let image = renderer.cgImage
        #expect(image != nil)
        #expect((image?.width ?? 0) > 0 && (image?.height ?? 0) > 0)
    }
}
