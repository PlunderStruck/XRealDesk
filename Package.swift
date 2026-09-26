// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "XRealDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "XRealDesk", targets: ["XRealDesk"]),
    ],
    targets: [
        // Private CoreGraphics virtual display API (same one DeskPad / BetterDisplay use).
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),
        // Pure logic: XREAL wire protocol, sensor fusion, layout geometry. No UI, testable.
        .target(
            name: "XRCore",
            path: "Sources/XRCore",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "XRealDesk",
            dependencies: ["XRCore", "CVirtualDisplay"],
            path: "Sources/XRealDesk",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // Self-checks for XRCore (XCTest isn't available with Command Line Tools only).
        .executableTarget(
            name: "xrcheck",
            dependencies: ["XRCore"],
            path: "Sources/xrcheck",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)
