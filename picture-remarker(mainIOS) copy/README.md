# Picture Remarker

Native iOS image annotation app built with SwiftUI.

## Overview

Picture Remarker lets you mark up product and review images locally on an iPhone. Image processing happens on the device, and the app can export a high-resolution annotated image for saving or sharing.

## Technology

- Swift 5
- SwiftUI with UIKit integration
- PhotosUI for importing images
- AVFoundation and `UIImagePickerController` for camera capture
- Core Graphics and ImageIO for image rendering and downsampling
- Photos for saving exported images
- iOS deployment target: iOS 18.0

## Features

- Import images from Photos
- Capture a photo with the camera
- Rectangle, line, arrow, and ellipse annotations
- Mosaic brush with adjustable brush and pixel sizes
- Add, move, scale, rotate, duplicate, and delete image layers
- Select, move, resize, and edit annotations
- Undo and redo editing steps
- High-resolution PNG export
- Save the result to Photos
- Share the exported image with the system share sheet
- Chinese and English interface languages

## Project layout

```text
ios/
├── PictureMarker/
│   ├── PictureMarkerApp.swift
│   ├── HomeView.swift
│   ├── EditorView.swift
│   ├── ImageCanvasView.swift
│   ├── AnnotatedImageRenderer.swift
│   ├── ExportView.swift
│   ├── Annotation*.swift
│   ├── ImageAsset.swift
│   ├── Overlay*.swift
│   ├── Localization.swift
│   ├── AppTheme.swift
│   └── Assets.xcassets/
└── PictureMarker.xcodeproj/
```

## Open and run

1. Open `ios/PictureMarker.xcodeproj` in Xcode.
2. Select the `PictureMarker` scheme.
3. Select an iPhone Simulator or a connected iPhone.
4. In Signing & Capabilities, select a development team if Xcode requests one.
5. Press Run.

The project builds directly with Xcode; no additional build step is required.

## Command-line build

Build for an iOS Simulator:

```bash
xcodebuild \
  -project ios/PictureMarker.xcodeproj \
  -scheme PictureMarker \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

For a distributable build, use Product → Archive in Xcode and export the archive from the Organizer.

## Permissions

The app requests only the permissions required by its features:

- Camera access for taking a photo
- Add-only Photos access for saving an exported image
- Photos access is handled through the system photo picker for importing images

## License

This project is available under the [MIT License](LICENSE).
