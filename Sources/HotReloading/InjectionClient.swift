//
//  InjectionClient.swift
//  InjectionIII
//
//  Created by John Holdsworth on 02/24/2021.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/InjectionClient.swift#27 $
//
//  Client app side of HotReloading started by +load
//  method in HotReloadingGuts/ClientBoot.mm
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
import HotReloadingGuts
import Xprobe
#endif

@objc(InjectionClient)
public class InjectionClient: SimpleSocket {

    public override func runInBackground() {
        let builder = SwiftInjectionEval.sharedInstance()
        builder.tmpDir = NSTemporaryDirectory()

        write(INJECTION_SALT)
        write(INJECTION_KEY)

        let frameworksPath = Bundle.main.privateFrameworksPath!
        write(builder.tmpDir)
        write(builder.arch)
        #if arch(arm64)
        var sign = "-"
        let signFile = Bundle(for: InjectionClient.self).path(forResource: "sign", ofType: nil) ?? ""
        if FileManager.default.fileExists(atPath: signFile) {
            let tempSign = try? String(contentsOfFile: signFile, encoding: .utf8).trimmingCharacters(in: Foundation.CharacterSet.newlines)
            sign = tempSign ?? "_"
        } else {
            print("💉 Not found \"sign\" file containing the app sign in the bundle. The dylib load may fail.")
        }
        print("💉 sign:\(sign), signFile:\(signFile)")
        write(sign)
        #endif
        write(Bundle.main.executablePath!)

        builder.tmpDir = readString() ?? "/tmp"

        var frameworkPaths = [String: String]()
        let isPlugin = builder.tmpDir == "/tmp"
        if (!isPlugin) {
            var frameworks = [String]()
            var sysFrameworks = [String]()

            for i in stride(from: _dyld_image_count()-1, through: 0, by: -1) {
                guard let imageName = _dyld_get_image_name(i),
                    strstr(imageName, ".framework/") != nil else {
                    continue
                }
                let imagePath = String(cString: imageName)
                let frameworkName = URL(fileURLWithPath: imagePath).lastPathComponent
                frameworkPaths[frameworkName] = imagePath
                if imagePath.hasPrefix(frameworksPath) {
                    frameworks.append(frameworkName)
                } else {
                    sysFrameworks.append(frameworkName)
                }
            }

            writeCommand(InjectionResponse.frameworkList.rawValue, with:
                frameworks.joined(separator: FRAMEWORK_DELIMITER))
            write(sysFrameworks.joined(separator: FRAMEWORK_DELIMITER))
            write(SwiftInjection.packageNames()
                .joined(separator: FRAMEWORK_DELIMITER))
        }

        var codesignStatusPipe = [Int32](repeating: 0, count: 2)
        pipe(&codesignStatusPipe)
        let reader = SimpleSocket(socket: codesignStatusPipe[0])
        let writer = SimpleSocket(socket: codesignStatusPipe[1])

        builder.signer = { dylib -> Bool in
            self.writeCommand(InjectionResponse.sign.rawValue, with: dylib)
            return reader.readString() == "1"
        }
        
//        let fileManager = FileManager.default
//        #if arch(arm64)
//        let injectDataPath = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first ?? ""
//        if fileManager.fileExists(atPath: injectDataPath) {
//            fileManager.createDirectory(at: injectDataPath, withIntermediateDirectories: false, attributes: [:])
//        }
//        #endif
        
        SwiftTrace.swizzleFactory = SwiftTrace.LifetimeTracker.self
        
        commandLoop:
        while true {
            let commandInt = readInt()
            guard let command = InjectionCommand(rawValue: commandInt) else {
                print("\(APP_PREFIX)Invalid commandInt: \(commandInt)")
                break
            }
            switch command {
            case .EOF:
                print("\(APP_PREFIX)EOF received from server..")
                break commandLoop
            case .signed:
                writer.write(readString() ?? "0")
            case .traceFramework:
                let frameworkName = readString() ?? "Misssing framework"
                if let frameworkPath = frameworkPaths[frameworkName] {
                    print("\(APP_PREFIX)Tracing %s\n", frameworkPath)
                    _ = SwiftTrace.interposeMethods(inBundlePath: frameworkPath,
                                                    packageName: nil)
                    SwiftTrace.trace(bundlePath:frameworkPath)
                } else {
                    print("\(APP_PREFIX)Tracing package \(frameworkName)")
                    let mainBundlePath = Bundle.main.executablePath ?? "Missing"
                    _ = SwiftTrace.interposeMethods(inBundlePath: mainBundlePath,
                                                    packageName: frameworkName)
                }
                filteringChanged()
            default:
                process(command: command, builder: builder)
            }
        }

        print("\(APP_PREFIX)\(APP_NAME) disconnected.")
    }

    func process(command: InjectionCommand, builder: SwiftEval) {
        switch command {
        case .vaccineSettingChanged:
            if let data = readString()?.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                builder.vaccineEnabled = json[UserDefaultsVaccineEnabled] as! Bool
            }
        case .connected:
            builder.projectFile = readString() ?? "Missing project"
            builder.derivedLogs = nil;
            print("\(APP_PREFIX)\(APP_NAME) connected \(builder.projectFile ?? "Missing Project")")
        case .watching:
            print("\(APP_PREFIX)Watching files under \(readString() ?? "Missing directory")")
        case .log:
            print(APP_PREFIX+(readString() ?? "Missing log message"))
        case .ideProcPath:
            builder.lastIdeProcPath = readString() ?? ""
        case .invalid:
            print("\(APP_PREFIX)⚠️ Server has rejected your connection. Are you running InjectionIII.app or start_daemon.sh from the right directory? ⚠️")
        case .quietInclude:
            SwiftTrace.traceFilterInclude = readString()
        case .include:
            SwiftTrace.traceFilterInclude = readString()
            filteringChanged()
        case .exclude:
            SwiftTrace.traceFilterExclude = readString()
            filteringChanged()
        case .feedback:
            SwiftInjection.traceInjection = readString() == "1"
        case .lookup:
            SwiftTrace.typeLookup = readString() == "1"
            if SwiftTrace.swiftTracing {
                print("\(APP_PREFIX)Discovery of target app's types switched \(SwiftTrace.typeLookup ? "on" : "off")");
            }
        case .trace:
            if SwiftTrace.traceMainBundleMethods() == 0 {
                print("\(APP_PREFIX)⚠️ Tracing Swift methods can only work if you have -Xlinker -interposable to your project's \"Other Linker Flags\"")
            } else {
                print("\(APP_PREFIX)Added trace to methods in main bundle")
            }
            filteringChanged()
        case .untrace:
            SwiftTrace.removeAllTraces()
        case .traceUI:
            if SwiftTrace.traceMainBundleMethods() == 0 {
                print("\(APP_PREFIX)⚠️ Tracing Swift methods can only work if you have -Xlinker -interposable to your project's \"Other Linker Flags\"")
            }
            SwiftTrace.traceMainBundle()
            print("\(APP_PREFIX)Added trace to methods in main bundle")
            filteringChanged()
        case .traceUIKit:
            DispatchQueue.main.sync {
                let OSView: AnyClass = (objc_getClass("UIView") ??
                    objc_getClass("NSView")) as! AnyClass
                print("\(APP_PREFIX)Adding trace to the framework containg \(OSView), this will take a while...")
                SwiftTrace.traceBundle(containing: OSView)
                print("\(APP_PREFIX)Completed adding trace.")
            }
            filteringChanged()
        case .traceSwiftUI:
            if let bundleOfAnyTextStorage = swiftUIBundlePath() {
                print("\(APP_PREFIX)Adding trace to SwiftUI calls.")
                _ = SwiftTrace.interposeMethods(inBundlePath: bundleOfAnyTextStorage, packageName:nil)
                filteringChanged()
            } else {
                print("\(APP_PREFIX)Your app doesn't seem to use SwiftUI.")
            }
        case .uninterpose:
            SwiftTrace.revertInterposes()
            SwiftTrace.removeAllTraces()
            print("\(APP_PREFIX)Removed all traces (and injections).")
            break;
        case .stats:
            let top = 200;
            print("""

                \(APP_PREFIX)Sorted top \(top) elapsed time/invocations by method
                \(APP_PREFIX)=================================================
                """)
            SwiftInjection.dumpStats(top:top)
            needsTracing()
        case .callOrder:
            print("""

                \(APP_PREFIX)Function names in the order they were first called:
                \(APP_PREFIX)===================================================
                """)
            for signature in SwiftInjection.callOrder() {
                print(signature)
            }
            needsTracing()
        case .fileOrder:
            print("""
                \(APP_PREFIX)Source files in the order they were first referenced:
                \(APP_PREFIX)=====================================================
                \(APP_PREFIX)(Order the source files should be compiled in target)
                """)
            SwiftInjection.fileOrder()
            needsTracing()
        case .counts:
            print("""
                \(APP_PREFIX)Counts of live objects by class:
                \(APP_PREFIX)================================
                """)
            SwiftInjection.objectCounts()
            needsTracing()
        case .fileReorder:
            writeCommand(InjectionResponse.callOrderList.rawValue,
                         with:SwiftInjection.callOrder().joined(separator: CALLORDER_DELIMITER))
            needsTracing()
        case .copy:
            if let data = readData() {
                DispatchQueue.main.async {
                    do {
                        builder.injectionNumber += 1
                        try data.write(to: URL(fileURLWithPath: "\(builder.tmpfile).dylib"))
                        try SwiftInjection.inject(tmpfile: builder.tmpfile)
                    } catch {
                        print("\(APP_PREFIX)⚠️ Injection error: \(error)")
                    }
                }
            }
        default:
            processOnMainThread(command: command, builder: builder)
        }
    }

    func processOnMainThread(command: InjectionCommand, builder: SwiftEval) {
        guard var changed = self.readString() else {
            print("\(APP_PREFIX)⚠️ Could not read changed filename?")
            return
        }
        
        let fileManager = FileManager.default
        #if arch(arm64)
        var injectDataPath = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? ""
        injectDataPath = (injectDataPath as NSString).appendingPathComponent("injectDatas")

        var isDirectoryExist: ObjCBool = true
        if !fileManager.fileExists(atPath: injectDataPath, isDirectory: &isDirectoryExist) {
            do {
                try fileManager.createDirectory(atPath: injectDataPath, withIntermediateDirectories: false, attributes: [:])
            } catch let err {
                print("文件夹创建失败 - \(injectDataPath): \(err.localizedDescription)")
            }
        }
        #endif
        
        if command == .load {
#if arch(arm64)
            let tmpFilePath = (injectDataPath as NSString).appendingPathComponent((changed as NSString).lastPathComponent)
            let dylibPath = (tmpFilePath as NSString).appendingPathExtension("dylib") ?? ""
            try? fileManager.removeItem(atPath: dylibPath)
            var dylibData = readData()
            fileManager.createFile(atPath: dylibPath, contents: dylibData, attributes: nil)
            changed = (dylibPath as NSString).deletingPathExtension
            let classes = (tmpFilePath as NSString).appendingPathExtension("classes") ?? ""
            try? fileManager.removeItem(atPath: classes)
            let classData = readData()
            fileManager.createFile(atPath: classes, contents: classData, attributes: nil)
#else
            let dylibString = (changed as NSString).appendingPathExtension("dylib") ?? ""
            let dylibData = NSData(contentsOfFile: dylibString)
            try? fileManager.removeItem(atPath: dylibString)
            dylibData?.write(toFile: dylibString, atomically: true)
#endif
        }
        
        DispatchQueue.main.async {
            var err: String?
            switch command {
            case .load:
                do {
                    builder.injectionNumber += 1
                    try SwiftInjection.inject(tmpfile: changed)
                } catch {
                    err = error.localizedDescription
                }
            case .inject:
                if changed.hasSuffix("storyboard") || changed.hasSuffix("xib") {
                    #if os(iOS) || os(tvOS)
                    if !NSObject.injectUI(changed) {
                        err = "Interface injection failed"
                    }
                    #else
                    err = "Interface injection not available on macOS."
                    #endif
                } else {
                    SwiftInjection.inject(oldClass:nil, classNameOrFile:changed)
                }
            case .xprobe:
                Xprobe.connect(to: nil, retainObjects:true)
                Xprobe.search("")
            case .eval:
                let parts = changed.components(separatedBy:"^")
                guard let pathID = Int(parts[0]) else { break }
                self.writeCommand(InjectionResponse.pause.rawValue, with:"5")
                if let object = (xprobePaths[pathID] as? XprobePath)?
                    .object() as? NSObject, object.responds(to: Selector(("swiftEvalWithCode:"))),
                   let code = (parts[3] as NSString).removingPercentEncoding,
                   object.swiftEval(code: code) {
                } else {
                    print("\(APP_PREFIX)Xprobe: Eval only works on NSObject subclasses where the source file has the same name as the class and is in your project.")
                }
                Xprobe.write("$('BUSY\(pathID)').hidden = true; ")
            default:
                print("\(APP_PREFIX)Unimplemented command: \(command.rawValue)")
            }
            let response: InjectionResponse = err != nil ? .error : .complete
            self.writeCommand(response.rawValue, with: err)
        }
    }

    func needsTracing() {
        if !SwiftTrace.swiftTracing {
            print("\(APP_PREFIX)⚠️ You need to have traced something to gather stats.")
        }
    }

    func filteringChanged() {
        if SwiftTrace.swiftTracing {
            let exclude = SwiftTrace.traceFilterExclude
            if let include = SwiftTrace.traceFilterInclude {
                print(String(format: exclude != nil ?
                   "\(APP_PREFIX)Filtering trace to include methods matching '%@' but not '%@'." :
                   "\(APP_PREFIX)Filtering trace to include methods matching '%@'.",
                   include, exclude != nil ? exclude! : ""))
            } else {
                print(String(format: exclude != nil ?
                   "\(APP_PREFIX)Filtering trace to exclude methods matching '%@'." :
                   "\(APP_PREFIX)Not filtering trace (Menu Item: 'Set Filters')",
                   exclude != nil ? exclude! : ""))
            }
        }
    }
}
