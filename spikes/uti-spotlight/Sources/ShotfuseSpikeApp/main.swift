import Foundation

// Stub binary for the Shotfuse UTI spike app bundle. Does nothing at runtime —
// its job is to exist at Contents/MacOS/ShotfuseSpikeApp so Launch Services
// treats the surrounding directory as a valid .app and picks up the UTI
// declarations in Info.plist.

print("Shotfuse UTI spike app — exists so Launch Services sees the bundle.")
