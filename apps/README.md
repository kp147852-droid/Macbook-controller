# Native Apps (iOS + macOS)

This repo includes native SwiftUI sources for both apps:
- `apps/macos/MacbookControllerMac`: macOS agent app (creates pair code, streams screen, executes remote input)
- `apps/ios/MacbookControlleriOS`: iPhone controller app (connects by pair code, renders frames, sends control events)

## Build with XcodeGen

1. Install XcodeGen:
```bash
brew install xcodegen
```

2. Generate the Xcode project:
```bash
cd apps
xcodegen generate
```

3. Open `MacbookController.xcodeproj` in Xcode.

4. Build and run:
- `MacbookControllerMac` on your Mac
- `MacbookControlleriOS` on your iPhone

## macOS permissions
On first run, grant the macOS app:
- Screen Recording
- Accessibility

Without these permissions, stream/control features will not work.
