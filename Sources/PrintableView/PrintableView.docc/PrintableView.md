# ``PrintableView``

Print a SwiftUI view to paper — or Save-as-PDF — on macOS and iPadOS.

## Overview

SwiftUI has no print pipeline of its own. `PrintableView` renders any `View` to a paginated
*vector* PDF using `ImageRenderer`'s render closure drawn into a `CGContext`, then hands that
PDF to the platform print machinery (`PDFDocument.printOperation` on macOS,
`UIPrintInteractionController` on iOS).

Because the output is vector rather than a rasterized bitmap, text prints crisp at the
printer's true resolution, stays selectable and searchable in a saved PDF, produces small
files, and avoids the memory spike of rasterizing a long document. Rendering through
`ImageRenderer` (rather than printing a hosted view directly) also sidesteps the blank-page
problem you hit when handing an `NSHostingView` to `NSPrintOperation`.

Call ``printDocument(_:jobTitle:pageSize:margins:)`` with the view you want to print, and
optionally build document-shaped content from the ``PrintSection`` and ``PrintCode``
primitives.

```swift
printDocument(
    PrintSection(title: "Interview Notes") {
        PrintCode(code: transcript)
    },
    jobTitle: "Interview Notes"
)
```

## Topics

### Printing

- ``printDocument(_:jobTitle:pageSize:margins:)``

### Layout primitives

- ``PrintSection``
- ``PrintCode``
