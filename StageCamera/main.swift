@preconcurrency import CoreMediaIO
import Foundation

// Stage Camera's system extension: serve the camera, then wait for clients.
let providerSource = CameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
