# NotchMusic

A macOS app that creates a floating notch for quick Music control with drag-and-drop file support.

## Features

- **Floating Notch Window**: A sleek, frosted-glass notch positioned at the top center of your screen
- **Music Controls**: 
  - Play/Pause toggle
  - Skip to next track
  - Skip to previous track
- **Now Playing Display**: Shows current track title and artist
- **Drag & Drop Files**: Drop files onto the file tray
- **Drag Files Out**: Drag files from the tray to any other application
- **Quit Button**: Easy access to quit the app
- **Always on Top**: Window floats above all other windows and spaces

## Requirements

- macOS 11.0 or later
- Xcode 13.0 or later
- Swift 5.5 or later

## Installation

1. Clone the repository
2. Open in Xcode
3. Build and run the project
4. The notch will appear at the top of your screen

## Usage

- **Play/Pause**: Click the play/pause button
- **Next Track**: Click the forward button
- **Previous Track**: Click the backward button
- **Add Files**: Drag and drop files onto the "Files" section
- **Use Files**: Drag files from the tray and drop them into any application
- **Quit**: Click the red "Quit" button

## Architecture

- **NotchMusicApp.swift**: SwiftUI app entry point
- **AppDelegate.swift**: Manages window creation and positioning
- **NotchViewModel.swift**: Handles Music player control and state management
- **NotchContentView.swift**: Main UI component with music controls
- **FileDropTray.swift**: File drag-and-drop implementation

## Future Enhancements

- Shuffle and repeat modes
- Customizable position and size
