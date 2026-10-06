# NotchDrop

A macOS app that creates a floating notch for quick Music control with drag-and-drop file support.

## Features

* **Floating Notch Window**: A sleek, frosted-glass notch positioned at the top center of your screen
* **Music Controls**:

  * Play/Pause toggle
  * Skip to next track
  * Skip to previous track
* **Now Playing Display**: Shows the current track title and artist
* **Drag & Drop Files**: Hold the Control key to drop files onto the file tray
* **Drag Files Out**: Drag files from the tray to any other application
* **Quit Button**: Easy access to quit the app
* **Always on Top**: Window floats above all other windows and Spaces

## Requirements

* macOS 11.0 or later
* Xcode 13.0 or later
* Swift 5.5 or later

## Installation

### Download the App

The easiest way to use NotchDrop is to download the latest release.

**[Download NotchDrop v2.0.0](https://github.com/Erik-RG/NotchDrop/releases/tag/v2.0.0)**

Download the app from the **Assets** section of the release, then open it on your Mac.

### Build from Source

You can also download the source code and build NotchDrop yourself.

1. Clone or download this repository.
2. Open Terminal and navigate to the project folder:

```bash
cd /path/to/NotchDrop
```

3. Make the build script executable:

```bash
chmod +x build.sh
```

4. Run the build script:

```bash
./build.sh
```

5. Once the build finishes, open the generated app.

> If you downloaded the source code as a ZIP file, extract it first, then use `cd` to navigate to the extracted NotchDrop folder.

## Usage

* **Play/Pause**: Click the play/pause button
* **Next Track**: Click the forward button
* **Previous Track**: Click the backward button
* **Add Files**: Drag and drop files onto the Files section
* **Use Files**: Drag files from the tray and drop them into any application
* **Quit**: Click the red Quit button

## Architecture

* **NotchDropApp.swift**: SwiftUI app entry point
* **AppDelegate.swift**: Manages window creation and positioning
* **NotchViewModel.swift**: Handles Music player control and state management
* **NotchContentView.swift**: Main UI component with music controls
* **FileDropTray.swift**: File drag-and-drop implementation

## Future Enhancements

* Shuffle and repeat modes
* Customizable position and size
