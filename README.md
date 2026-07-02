# PrintableView

Print a SwiftUI view to paper — or Save-as-PDF — on macOS and iPadOS, in one call.

[Documentation](https://swiftpackageindex.com/adamtheturtle/PrintableView/documentation/printableview) |
[Swift Package Index](https://swiftpackageindex.com/adamtheturtle/PrintableView)

SwiftUI has no print pipeline of its own. `ImageRenderer` gets you a PDF *file*, but sending
a view to the actual print panel means dropping down to `NSPrintOperation` /
`UIPrintInteractionController` and rediscovering a pile of gotchas: hand an `NSHostingView`
straight to `NSPrintOperation` and you get blank pages, because a layer-backed SwiftUI view's
content never travels through the AppKit `draw(_:)` path the print system captures; skip the
color-scheme override and adaptive colors print white-on-white in dark mode.

`PrintableView` renders your view to a **paginated vector PDF** (via `ImageRenderer`'s render
closure drawn into a `CGContext`) and hands that to the platform print panel. Because the
output is vector, text prints crisp at the printer's true resolution, stays selectable and
searchable in a saved PDF, produces small files, and avoids the large-bitmap memory spike of
rasterizing a long document.

```swift
import PrintableView

Button("Print") {
    printDocument(
        PrintSection(title: "Interview Notes") {
            PrintCode(code: transcript)
        },
        jobTitle: "Interview Notes"
    )
}
```

## Installation

```swift
.package(url: "https://github.com/adamtheturtle/PrintableView.git", from: "0.1.0")
```

Add the `PrintableView` product to your target dependencies.

## API

- `printDocument(_:jobTitle:pageSize:margins:)` — render a view to a vector PDF and present
  the print panel. `pageSize` defaults to the platform's default paper; `margins` default to
  36pt (half an inch).
- `PrintSection` — a titled block (heading over content) for document-shaped layouts.
- `PrintCode` — wrapping monospaced text for printing code without horizontal clipping.

## Notes & limitations

- Like all `ImageRenderer` output, views backed by native platform frameworks (`MapKit`
  maps, `WKWebView`, `AVPlayer`, Metal/SceneKit) render as blank rectangles.
- Pagination is by vertical position: content taller than one page is split into
  page-height bands, so a line sitting on a page boundary can be divided across the break.
  Content-aware pagination is not attempted.

## Requirements

- Swift 6.2+
- macOS 13+ or iOS 16+

## License

MIT. See [LICENSE](LICENSE).
