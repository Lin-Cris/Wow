# Teleprompter

Native iOS teleprompter and video recording app built with SwiftUI and AVFoundation.

## Features

- Edit and display a script as a teleprompter.
- Read a narrow, phrase-wrapped column through a fixed focus near the front camera; upcoming text fades and previous text falls away.
- Smooth display-synchronized scrolling retains the words being read when font size or orientation changes.
- Adjust prompt size, font size, scroll speed, and starting position.
- Preview the front camera and record silent video without interrupting background audio or calls.
- Save recordings to Photos.

## Tech stack

- Swift 5 and SwiftUI
- AVFoundation
- Photos
- iOS 17.0 or later

## Run on iPhone

1. Open `TeleprompterApp.xcodeproj` in Xcode.
2. Select the `TeleprompterApp` scheme and an iPhone device.
3. Select the development team for the `TeleprompterApp` target if needed.
4. Run the app and allow camera and Photos access when prompted.

The simulator uses a camera placeholder so the teleprompter UI can be tested without camera hardware.

## Project structure

```text
TeleprompterApp/
├── App/                 # SwiftUI app entry point
├── Features/
│   ├── ScriptEditor/    # Script input screen
│   └── Teleprompter/    # Prompt display and controls
├── Camera/              # Camera preview, recording, and Photos saving
└── Assets.xcassets/     # App icon and color assets
```
