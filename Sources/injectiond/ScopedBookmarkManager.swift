//
//  ScopedBookmarkManager.swift
//  InjectionIII
//
//  Created by klone on 2021/12/7.
//  Copyright © 2021 John Holdsworth. All rights reserved.
//

import Cocoa

@objc public class ScopedBookmarkManager: NSObject {
    @objc public class func saveBookmark(_ url: URL, key: String) -> Bool {
        guard let bookmarkData = try? url.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) else {
                                                        return false
        }
        UserDefaults.standard.set(bookmarkData, forKey: key)
        UserDefaults.standard.synchronize()
        return true
    }
    
    @objc public class func bookmark(for key: String) -> URL? {
        var isStale = false
        guard let bookmarkData = UserDefaults.standard.object(forKey: key),
            let url = try? URL.init(resolvingBookmarkData: bookmarkData as! Data,
                                    options: .withSecurityScope,
                                    relativeTo: nil,
                                    bookmarkDataIsStale: &isStale) else {
                                        return nil
        }
        return url
    }
    
    @objc public class func startAccessing(for key: String) -> Bool {
        guard let url = self.bookmark(for: key) else {
            return false
        }
        return url.startAccessingSecurityScopedResource()
    }
    
    @objc public class func stopAccessing(for key: String) {
        self.bookmark(for: key)?.stopAccessingSecurityScopedResource()
    }
}

@objc public class DirectoryAccessHelper: NSObject, NSOpenSavePanelDelegate {
    var url: URL?
    
    @objc public func askPermission(for url: URL, bookmark key: String, app name: String) -> Bool {
        self.url = url;
        
        let openPanel = NSOpenPanel.init()
        openPanel.delegate = self
        openPanel.directoryURL = url
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.message = "\(name) needs to access this directory to continue. Click \"Allow\" to continue."
        openPanel.prompt = "Allow"
        if openPanel.runModal() == .OK {
            return ScopedBookmarkManager.saveBookmark(openPanel.url!, key: key);
        }
        return false
    }

    public func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        return url.path == self.url?.path
    }
}

