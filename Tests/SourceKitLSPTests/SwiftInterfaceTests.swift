//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import ISDBTestSupport
import LSPLogging
import LSPTestSupport
import LanguageServerProtocol
import SKSupport
import SKTestSupport
import SourceKitLSP
import XCTest

final class SwiftInterfaceTests: XCTestCase {
  func testSystemModuleInterface() async throws {
    // This is the only test that references modules from the SDK (Foundation).
    // `testSystemModuleInterface` has been flaky for a long while and a
    // hypothesis is that it was failing because of a malformed global module
    // cache that might still be present from previous CI runs. If we use a
    // local module cache, we define away that source of bugs.
    let testClient = try await TestSourceKitLSPClient(useGlobalModuleCache: false)
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let uri = DocumentURI(url)

    testClient.openDocument("import Foundation", uri: uri)

    let _resp = try await testClient.send(
      DefinitionRequest(
        textDocument: TextDocumentIdentifier(url),
        position: Position(line: 0, utf16index: 10)
      )
    )
    let resp = try XCTUnwrap(_resp)
    guard case .locations(let locations) = resp else {
      XCTFail("Unexpected response: \(resp)")
      return
    }
    XCTAssertEqual(locations.count, 1)
    let location = try XCTUnwrap(locations.first)
    XCTAssertTrue(location.uri.pseudoPath.hasSuffix("/Foundation.swiftinterface"))
    let fileContents = try XCTUnwrap(location.uri.fileURL.flatMap({ try String(contentsOf: $0, encoding: .utf8) }))
    // Sanity-check that the generated Swift Interface contains Swift code
    XCTAssert(
      fileContents.hasPrefix("import "),
      "Expected that the foundation swift interface starts with 'import ' but got '\(fileContents.prefix(100))'"
    )
  }

  func testOpenInterface() async throws {
    let ws = try await SwiftPMTestWorkspace(
      files: [
        "MyLibrary/MyLibrary.swift": """
        public struct Lib {
          public func foo() {}
          public init() {}
        }
        """,
        "Exec/main.swift": "import MyLibrary",
      ],
      manifest: """
        // swift-tools-version: 5.7

        import PackageDescription

        let package = Package(
          name: "MyLibrary",
          targets: [
            .target(name: "MyLibrary"),
            .executableTarget(name: "Exec", dependencies: ["MyLibrary"])
          ]
        )
        """,
      build: true
    )

    let (mainUri, _) = try ws.openDocument("main.swift")
    let openInterface = OpenInterfaceRequest(
      textDocument: TextDocumentIdentifier(mainUri),
      name: "MyLibrary",
      symbolUSR: nil
    )
    let interfaceDetails = try unwrap(await ws.testClient.send(openInterface))
    XCTAssert(interfaceDetails.uri.pseudoPath.hasSuffix("/MyLibrary.swiftinterface"))
    let fileContents = try XCTUnwrap(
      interfaceDetails.uri.fileURL.flatMap({ try String(contentsOf: $0, encoding: .utf8) })
    )
    XCTAssertTrue(
      fileContents.contains(
        """
        public struct Lib {

            public func foo()

            public init()
        }
        """
      )
    )
  }

  /// Used by testDefinitionInSystemModuleInterface
  func testSystemSwiftInterface(
    _ testLoc: TestLocation,
    ws: SKSwiftPMTestWorkspace,
    swiftInterfaceFile: String,
    linePrefix: String
  ) async throws {
    try ws.openDocument(testLoc.url, language: .swift)
    let definition = try await ws.testClient.send(
      DefinitionRequest(
        textDocument: testLoc.docIdentifier,
        position: testLoc.position
      )
    )
    guard case .locations(let jump) = definition else {
      XCTFail("Response is not locations")
      return
    }
    let location = try XCTUnwrap(jump.first)
    XCTAssertTrue(location.uri.pseudoPath.hasSuffix(swiftInterfaceFile), "Path was: '\(location.uri.pseudoPath)'")
    // load contents of swiftinterface
    let contents = try XCTUnwrap(location.uri.fileURL.flatMap({ try String(contentsOf: $0, encoding: .utf8) }))
    let lineTable = LineTable(contents)
    let line = lineTable[location.range.lowerBound.line]
    XCTAssert(line.hasPrefix(linePrefix), "Full line was: '\(line)'")
    ws.closeDocument(testLoc.url)
  }

  func testDefinitionInSystemModuleInterface() async throws {
    guard let ws = try await staticSourceKitSwiftPMWorkspace(name: "SystemSwiftInterface") else { return }
    try ws.buildAndIndex(withSystemSymbols: true)
    let stringRef = ws.testLoc("lib.string")
    let intRef = ws.testLoc("lib.integer")
    let withTaskGroupRef = ws.testLoc("lib.withTaskGroup")

    // Test stdlib with one submodule
    try await testSystemSwiftInterface(
      stringRef,
      ws: ws,
      swiftInterfaceFile: "/Swift.String.swiftinterface",
      linePrefix: "@frozen public struct String"
    )
    // Test stdlib with two submodules
    try await testSystemSwiftInterface(
      intRef,
      ws: ws,
      swiftInterfaceFile: "/Swift.Math.Integers.swiftinterface",
      linePrefix: "@frozen public struct Int"
    )
    // Test concurrency
    try await testSystemSwiftInterface(
      withTaskGroupRef,
      ws: ws,
      swiftInterfaceFile: "/_Concurrency.swiftinterface",
      linePrefix: "@inlinable public func withTaskGroup"
    )
  }

  func testSwiftInterfaceAcrossModules() async throws {
    let ws = try await SwiftPMTestWorkspace(
      files: [
        "MyLibrary/MyLibrary.swift": """
        public struct Lib {
          public func foo() {}
          public init() {}
        }
        """,
        "Exec/main.swift": "import 1️⃣MyLibrary",
      ],
      manifest: """
        // swift-tools-version: 5.7

        import PackageDescription

        let package = Package(
          name: "MyLibrary",
          targets: [
            .target(name: "MyLibrary"),
            .executableTarget(name: "Exec", dependencies: ["MyLibrary"])
          ]
        )
        """,
      build: true
    )

    let (mainUri, mainPositions) = try ws.openDocument("main.swift")
    let _resp =
      try await ws.testClient.send(
        DefinitionRequest(
          textDocument: TextDocumentIdentifier(mainUri),
          position: mainPositions["1️⃣"]
        )
      )
    let resp = try XCTUnwrap(_resp)
    guard case .locations(let locations) = resp else {
      XCTFail("Unexpected response: \(resp)")
      return
    }
    XCTAssertEqual(locations.count, 1)
    let location = try XCTUnwrap(locations.first)
    XCTAssertTrue(location.uri.pseudoPath.hasSuffix("/MyLibrary.swiftinterface"))
    let fileContents = try XCTUnwrap(location.uri.fileURL.flatMap({ try String(contentsOf: $0, encoding: .utf8) }))
    XCTAssertTrue(
      fileContents.contains(
        """
        public struct Lib {

            public func foo()

            public init()
        }
        """
      ),
      "Generated interface did not contain expected text.\n\(fileContents)"
    )
  }
}
