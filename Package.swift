// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SqlCipherKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SqlCipherKit", targets: ["SqlCipherKit"])
    ],
    targets: [
        // MARK: - C amalgamation target
        .target(
            name: "CSqlCipher",
            path: "Sources/CSqlCipher",
            sources: ["sqlite3.c"],
            publicHeadersPath: "include",
            cSettings: [
                // Core SqlCipher compile-time requirements
                .define("SQLITE_HAS_CODEC"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
                .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
                .define("SQLITE_THREADSAFE", to: "1"),

                // Crypto provider — CommonCrypto on Apple, OpenSSL on Linux
                .define(
                    "SQLCIPHER_CRYPTO_CC",
                    .when(platforms: [.macOS, .iOS, .visionOS])),
                .define(
                    "SQLCIPHER_CRYPTO_OPENSSL",
                    .when(platforms: [.linux])),

                // Let SQLite's amalgamation include <stdint.h> for uint64_t etc.
                .define("HAVE_STDINT_H", to: "1"),

                // Reduce binary size / build noise
                .define("NDEBUG"),
                .define("SQLITE_DQS", to: "0"),
            ],
            linkerSettings: [
                // CommonCrypto lives in the Security framework on Apple platforms
                .linkedFramework(
                    "Security",
                    .when(platforms: [.macOS, .iOS, .visionOS])),
                // OpenSSL's crypto library on Linux (requires libssl-dev)
                .linkedLibrary(
                    "crypto",
                    .when(platforms: [.linux])),
            ]
        ),

        // MARK: - Swift wrapper target
        .target(
            name: "SqlCipherKit",
            dependencies: ["CSqlCipher"],
            path: "Sources/SqlCipherKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "SqlCipherKitTests",
            dependencies: ["SqlCipherKit"],
            path: "Tests/SqlCipherKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
