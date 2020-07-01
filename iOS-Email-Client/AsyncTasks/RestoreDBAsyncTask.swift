//
//  RestoreDBAsyncTask.swift
//  iOS-Email-Client
//
//  Created by Pedro Iniguez on 4/10/19.
//  Copyright © 2019 Criptext Inc. All rights reserved.
//

import Foundation
import Zip

class RestoreDBAsyncTask {
    let path: String
    let accountId: String
    let initialProgress: Int
    let restoreFolder: String
    
    init(path: String, accountId: String, initialProgress: Int = 0) {
        self.path = path
        self.accountId = accountId
        self.initialProgress = initialProgress
        
        let myTimestamp = Date().timeIntervalSince1970
        self.restoreFolder = "restore-\(myTimestamp)"
    }
    
    func start(progressHandler: @escaping ((Int) -> Void), completion: @escaping ((CriptextError?) -> Void)) {
        let startTime = Date().timeIntervalSince1970
        let queue = DispatchQueue(label: "com.email.loaddb", qos: .userInteractive, attributes: .concurrent)
        queue.async {
            let fileUrl = URL(string: self.path)!
            
            let data = try? FileManager.default.attributesOfItem(atPath: fileUrl.path)
            print(data)
            do {
                let destinationUrl = FileUtils.getRestoreFolderUrl(name: self.restoreFolder)
                try FileManager.default.createDirectory(at: destinationUrl, withIntermediateDirectories: true, attributes: nil)
                try Zip.unzipFile(fileUrl, destination: destinationUrl, overwrite: true, password: nil)
            } catch let error {
                print(error)
            }
            
            let fileURLs = try? FileManager.default.contentsOfDirectory(at: FileUtils.getRestoreFolderUrl(name: self.restoreFolder), includingPropertiesForKeys: nil, options: [] )
            print(fileURLs ?? "NO FILES")

            let liteUrl = FileUtils.getBackupUrl(name: "lite.db", folder: self.restoreFolder)
            let result1 = self.handleFile(url: liteUrl, progressHandler: progressHandler)
            
            let endliteTime = Date().timeIntervalSince1970
            print("RESTORE LITE : \(endliteTime - startTime)")
            
            DispatchQueue.main.async {
                completion(nil)
            }
            
            let completeUrl = FileUtils.getBackupUrl(name: "complete.db", folder: self.restoreFolder)
            let result2 = self.handleFile(url: completeUrl, progressHandler: progressHandler)
            
            let endCompleteTime = Date().timeIntervalSince1970
            print("RESTORE DONE : \(endCompleteTime - endliteTime) : \(endCompleteTime - startTime)")
        }
    }
    
    func handleFile(url: URL, progressHandler: @escaping ((Int) -> Void)) -> Error? {
        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let streamReader = StreamReader(url: url, delimeter: "\n", encoding: .utf8, chunkSize: 2048) else {
                return CriptextError.init(message: "No File")
        }
        let fileSize = UInt64(truncating: fileAttributes[.size] as! NSNumber)
        var dbRows = [[String: Any]]()
        let systemLabels = [
            SystemLabel.inbox.rawValue: SystemLabel.inbox.rawValue,
            SystemLabel.spam.rawValue: SystemLabel.spam.rawValue,
            SystemLabel.sent.rawValue: SystemLabel.sent.rawValue,
            SystemLabel.trash.rawValue: SystemLabel.trash.rawValue,
            SystemLabel.starred.rawValue: SystemLabel.starred.rawValue,
            SystemLabel.draft.rawValue: SystemLabel.draft.rawValue
        ]
        var maps = LinkDBMaps.init(emails: [Int: Int](), contacts: [Int: String](), labels: systemLabels)
        let account = DBManager.getAccountById(self.accountId)!
        var line = streamReader.nextLine()
        
        guard let metadata = LinkFileHeaderData.fromDictionary(dictionary: Utils.convertToDictionary(text: line!)),
            account.email == "\(metadata.recipientId)@\(metadata.domain)",
            let fileHandler = try? LinkFileMiddleware(version: metadata.fileVersion) else {
            return CriptextError(message: String.localize("LINK_FILE_METADATA_ERROR"))
        }
        
        line = streamReader.nextLine()
        while line != nil {
            guard let row = Utils.convertToDictionary(text: line!) else {
                continue
            }
            var progress = Int((100 - UInt64(self.initialProgress)) * streamReader.currentPosition/fileSize) + self.initialProgress
            dbRows.append(row)
            if dbRows.count >= 30 {
                fileHandler.insertBatchRows(rows: dbRows, maps: &maps, accountId: self.accountId)
                dbRows.removeAll()
                if progress > 99 {
                    progress = 99
                }
                DispatchQueue.main.async {
                    progressHandler(progress)
                }
            }
            line = streamReader.nextLine()
        }
        fileHandler.insertBatchRows(rows: dbRows, maps: &maps, accountId: self.accountId)
        CriptextFileManager.deleteFile(path: self.path)
        return nil
    }
}
