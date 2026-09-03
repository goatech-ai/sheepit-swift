# SheepitSDK

The official [Sheepit](https://www.sheepit.ai) SDK for Apple platforms — feature
flags, experiments, analytics, crash and performance reporting, and release
intelligence for iOS, macOS, tvOS and watchOS.

> **This repository is a read-only distribution mirror.** It exists because Swift
> Package Manager resolves packages from a public Git URL. Releases are published
> here automatically; please open issues and questions at
> [sheepit.ai](https://www.sheepit.ai) rather than as pull requests against this
> mirror.

## Installation

Add the package in Xcode via **File → Add Package Dependencies…**, or declare it
in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/goatech-ai/sheepit-swift.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "SheepitSDK", package: "sheepit-swift"),
    ]),
]
```

## Quick start

```swift
import SheepitSDK

let sheepit = Sheepit.initialize(
    config: SheepitConfig(apiKey: "lp_pub_…", environment: "production")
)

if sheepit.flag("new_checkout").boolValue {
    // …
}
```

Use a **publishable** key (`lp_pub_…`) in a client app. Never embed a secret key.

## Requirements

| Platform | Minimum |
| :------- | :------ |
| iOS      | 16.0    |
| macOS    | 13.0    |
| tvOS     | 16.0    |
| watchOS  | 9.0     |

## Licence

See [LICENSE](LICENSE).
