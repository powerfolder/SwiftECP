# SwiftECP

[![Version](https://img.shields.io/cocoapods/v/SwiftECP.svg?style=flat)](http://cocoapods.org/pods/SwiftECP)
[![License](https://img.shields.io/cocoapods/l/SwiftECP.svg?style=flat)](http://cocoapods.org/pods/SwiftECP)
[![Platform](https://img.shields.io/cocoapods/p/SwiftECP.svg?style=flat)](http://cocoapods.org/pods/SwiftECP)

Need Shibboleth login on your iOS app but don't want to use a webview? Don't want to deal with XML or read a spec? Use SwiftECP to do the work for you!

SwiftECP is a spec-conformant Shibboleth ECP client for iOS. Simply provide credentials and a Shibboleth-protected resource URL and SwiftECP will hand you a Shibboleth cookie to attach to further requests or inject into a webview.

## Usage

```swift
ECP(
	username: "YOUR_USERNAME",
	password: "YOUR_PASSWORD"
	protectedURL: NSURL(
		string: "https://app.university.edu/protected"
	)!
).login().then { request, response, body -> Void in
	// If the request was successful, the protected resource will
	// be available in 'body'. Make sure to implement a mechanism to
	// detect authorization timeouts.
	println(body)

	// The Shibboleth auth cookie is now stored in the sharedHTTPCookieStorage.
	// Attach this cookie to subsequent requests to protected resources.
	// You can access the cookie with the following code:
	if let cookies = NSHTTPCookieStorage.sharedHTTPCookieStorage().cookies as? [NSHTTPCookie] {
		let shibCookie = cookies.filter { (cookie: NSHTTPCookie) in
			cookie.name.rangeOfString("shibsession") != nil
		}[0]
		println(shibCookie)
	}
}.catch { error in
	// This is an NSError containing both a user-friendly message and a
	// technical debug message. This can help diagnose problems with your
	// SP, your IdP, or even this library :)
	
    // User-friendly error message
    println(error.localizedDescription)

    // Technical/debug error message
    println(error.localizedFailureReason)
}
```

## Test

To run the example project, clone the repo, and run `pod install` from the Example directory first.

You can test your SP and IdP's ECP configuration by opening the example project and replacing username, password, and protectedURL with your own.

## Installation

SwiftECP is available through [CocoaPods](http://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod "SwiftECP"
```

## Todo

- Unit and integration tests
- Detailed documentation

Pull requests are welcome and encouraged!

## Author

Tyler Thompson, tpthomp@clemson.edu

## License

SwiftECP is available under the Apache 2.0 license. See the LICENSE file for more info.
