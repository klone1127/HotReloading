//
//  ReducerInjection.swift
//
//  Created by John Holdsworth on 09/06/2022.
//  Copyright © 2022 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/ReducerInjection.swift#1 $
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
import DLKit
#endif

extension NSObject {

    @objc
    public func registerInjectableTCAReducer(_ symbol: String) {
        _ = SwiftInjection.checkReducerInitializers
        SwiftInjection.injectableReducerSymbols.insert(symbol)
    }
}

extension SwiftInjection {

    static var injectableReducerSymbols = Set<String>()
    
    static var checkReducerInitializers: Void = {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            var expectedInjectableReducerSymbols = Set<String>()

            findHiddenSwiftSymbols(searchBundleImages(), "Reducer_WZ", .any) {
                _, symname, _, _ in
                expectedInjectableReducerSymbols.insert(String(cString: symname))
            }

            for sym in expectedInjectableReducerSymbols
                .subtracting(injectableReducerSymbols) {
                log("⚠️ Not injectable or not used:",
                    SwiftMeta.demangle(symbol: sym) ?? sym)
            }
        }
    }()

    /// Support for re-initialising "The Composable Architecture", "Reducer"
    /// variables declared at the top level. Requires custom version of TCA:
    /// https://github.com/thebrowsercompany/swift-composable-architecture/tree/develop
    static func reinitializeInjectedReducers(_ tmpfile: String,
                reinitialized: UnsafeMutablePointer<[SymbolName]>) {
        findHiddenSwiftSymbols(searchLastLoaded(), "_WZ", .local) {
            accessor, symname, _, _ in
            if injectableReducerSymbols.contains(String(cString: symname)) {
                typealias OneTimeInitialiser = @convention(c) () -> Void
                let reinitialise: OneTimeInitialiser = autoBitCast(accessor)
                reinitialise()
                reinitialized.pointee.append(symname)
            }
        }
    }
}