// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "StudyTours",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "StudyTours", targets: ["StudyTours"]),
        // Shared with the iPad app (iPad/project.yml).
        .library(name: "StudyToursCore", targets: ["StudyToursCore"])
    ],
    targets: [
        // Pure logic + API clients. No UI, fully unit-testable.
        .target(name: "StudyToursCore"),
        // SwiftUI macOS app.
        .executableTarget(name: "StudyTours", dependencies: ["StudyToursCore"]),
        .testTarget(name: "StudyToursCoreTests", dependencies: ["StudyToursCore"])
    ]
)
