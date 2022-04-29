// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TwitterLoggingService",
    platforms: [.iOS(.v10)],
    products: [
        .library(name: "TwitterLoggingService", targets: ["TwitterLoggingService"]),
        .library(name: "TwitterLoggingServiceExt", targets: ["TwitterLoggingServiceExt"]),
        .library(name: "TwitterLoggingServiceObjC", targets: ["TwitterLoggingServiceObjC"])
    ],
    targets: [
        .target(name: "TwitterLoggingServiceObjC"),
        .target(name: "TwitterLoggingService", dependencies: ["TwitterLoggingServiceObjC"]),
        .target(name: "TwitterLoggingServiceExt", dependencies: ["TwitterLoggingServiceObjC"]),
        .testTarget(
            name: "TwitterLoggingServiceTests",
            dependencies: ["TwitterLoggingService"]
        ),
        .testTarget(
            name: "TwitterLoggingServiceObjCTests",
            dependencies: ["TwitterLoggingServiceObjC"]
        )
    ]
)
