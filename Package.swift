// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WallpaperSchedule",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WallpaperSchedule", targets: ["WallpaperSchedule"]),
        .executable(name: "WallpaperScheduler", targets: ["WallpaperScheduler"])
    ],
    targets: [
        .target(name: "WallpaperCore"),
        .executableTarget(name: "WallpaperSchedule", dependencies: ["WallpaperCore"]),
        .executableTarget(name: "WallpaperScheduler", dependencies: ["WallpaperCore"]),
        .testTarget(name: "WallpaperCoreTests", dependencies: ["WallpaperCore"])
    ]
)
