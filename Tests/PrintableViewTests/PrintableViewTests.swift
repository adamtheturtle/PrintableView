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
