# PrintableView

Print a SwiftUI view to paper or Save-as-PDF on macOS and iPadOS.

[Documentation](https://swiftpackageindex.com/adamtheturtle/PrintableView/documentation/printableview) |
[Swift Package Index](https://swiftpackageindex.com/adamtheturtle/PrintableView)

## Installation

```swift
.package(url: "https://github.com/adamtheturtle/PrintableView.git", from: "0.1.0")
```

Add the `PrintableView` product to your target dependencies.

## Product

- `PrintableView`: Render SwiftUI content to a paginated vector PDF and present the
  platform print panel.

## Basic printing

```swift
import PrintableView

let outcome = try await printDocument(
    PrintSection(title: "Interview Notes") {
        PrintCode(code: transcript)
    },
    jobTitle: "Interview Notes"
)
```

The throwing API reports whether printing completed or the user cancelled. It throws a
`PrintDocumentError` if PDF handoff, print-panel presentation, or printing fails.

## Rendering PDF data

PDF generation is separate from print-panel presentation, so it can be saved, shared, or
tested without displaying UI:

```swift
let configuration = PrintConfiguration(
    pageSize: CGSize(width: 612, height: 792),
    jobTitle: "Interview Notes"
)

let pdfData = try renderPDF(configuration: configuration) {
    InterviewNotesView()
}
```

When `pageSize` is omitted, rendering uses US Letter (612 × 792 pt). Pass an explicit size
such as A4 (`CGSize(width: 595.28, height: 841.89)`) when you need a different stock.

Invalid page sizes, margins, and footer heights throw `PrintDocumentError` rather than
silently producing an empty document.

## Adding a source-attribution footer

```swift
let configuration = PrintConfiguration(
    footer: .attribution(sourceURL: sourceURL),
    jobTitle: "Reference"
)

let outcome = try await printDocument(configuration: configuration) {
    ReferenceView()
}
```

The convenience footer draws `https://example.com/resource • Page 2 of 5`. For other text,
use `PrintFooter { page, pageCount in ... }`. Footer output is constrained and clipped to a
single bounded area on every page.

## Requirements

- Swift 6.2+
- macOS 13+ or iOS 16+

## License

MIT. See [LICENSE](LICENSE).
