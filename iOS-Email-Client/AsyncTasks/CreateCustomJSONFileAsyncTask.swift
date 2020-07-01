//
//  CreateCustomJSONFileAsyncTask.swift
//  iOS-Email-Client
//
//  Created by Pedro Aim on 7/16/18.
//  Copyright © 2018 Criptext Inc. All rights reserved.
//

import Foundation
import SignalProtocolFramework
import RealmSwift
import Zip

class CreateCustomJSONFileAsyncTask {
    
    enum Kind {
        case link
        case backup
    }
    
    enum Stage {
        case lite
        case complete
    }
    
    init(accountId: String, kind: Kind = .link, password: String? = nil) {
        self.accountId = accountId
        self.kind = kind
        self.password = password
        
        let myTimestamp = Date().timeIntervalSince1970
        self.backupFolder = "backup-\(myTimestamp)"
    }
    
    let password: String?
    var kind: Kind
    var accountId: String
    var stage: Stage = .lite
    var backupFolder: String
    
    func start(progressHandler: @escaping ((Int, Stage) -> Void), completion: @escaping ((Error?, URL?) -> Void)){
        DispatchQueue.global().async {
            let (liteUrl, emailKeys) = self.createInitialDBFile(progressHandler: progressHandler)
            
            self.stage = .complete
            let (error, completeUrl) = self.createDBFile(emailKeys: emailKeys, progressHandler: progressHandler)
            
            let compressName = "\(self.accountId)-db.zip"
            let compressUrl = FileUtils.getBackupUrl(name: compressName, folder: self.backupFolder)
            try? Zip.zipFiles(paths: [liteUrl, completeUrl!], zipFilePath: compressUrl, password: nil, progress: nil)
            
            var encryptPath: String? = nil
            if let pass = self.password {
                let encryptedName = "encrypted.db"
                let encryptedUrl = FileUtils.getBackupUrl(name: encryptedName, folder: self.backupFolder)
                encryptPath = AESCipher.streamEncrypt(path: compressUrl.path, outputPath: encryptedUrl, bundle: AESCipher.KeyBundle(password: pass, salt: AESCipher.generateRandomBytes(length: 8)), ivData: AESCipher.generateRandomBytes(length: 16), operation: kCCEncrypt)
            }
            let dbUrl = encryptPath != nil ? URL(string: encryptPath!)! : compressUrl
            
            DispatchQueue.main.async {
                completion(error, dbUrl)
            }
        }
    }
    
    private func createInitialDBFile(progressHandler: @escaping ((Int, Stage) -> Void)) -> (URL, [Int]) {
        let fileUrl = FileUtils.getBackupUrl(name: "lite.db", folder: backupFolder)
        
        let account = DBManager.getAccountById(self.accountId)!
        var progress = 0
        
        let backupDBManager = BackupDBManager()
        
        let emails = backupDBManager.getThreads(from: SystemLabel.inbox.id, since: Date(), limit: 20, account: account)
        
        var dispatchedContacts = [String: Int]()
        var dispatchedLabels = [String: Int]()
        var dispatchedEmails = [Int: Int]()
        
        let metadata = LinkFileHeaderData(recipientId: account.username, domain: account.domain ?? Env.plainDomain)
        metadata.fillFromAccount(account)
        metadata.darkTheme = CriptextDefaults().themeMode == "Dark"
        metadata.language = Env.language
        handleRow(metadata.toDictionary(), url: fileUrl)
        progress = handleProgress(progress: progress, total: 9, step: 1, progressHandler: progressHandler)
        emails.map({$0.getContacts()}).flatMap({$0}).enumerated().forEach {
            guard dispatchedContacts[$1.email] == nil else {
                return
            }
            dispatchedContacts[$1.email] = $0 + 1
            handleRow($1.toDictionary(id: $0 + 1), url: fileUrl)
        }
        progress = handleProgress(progress: progress, total: 9, step: 2, progressHandler: progressHandler)
        emails.map({$0.labels}).flatMap({$0}).enumerated().forEach {
            guard dispatchedLabels[$1.uuid] == nil && SystemLabel(rawValue: $1.id) == nil  else {
                return
            }
            dispatchedLabels[$1.uuid] = $0 + 1
            handleRow($1.toDictionary(), url: fileUrl)
        }
        progress = handleProgress(progress: progress, total: 9, step: 3, progressHandler: progressHandler)
        emails.enumerated().forEach {
            dispatchedEmails[$1.key] = $0 + 1
            let dictionary = $1.toDictionary(
                id: $0 + 1,
                emailBody: FileUtils.getBodyFromFile(account: account, metadataKey: "\($1.key)"),
                headers: FileUtils.getHeaderFromFile(account: account, metadataKey: "\($1.key)"))
            handleRow(dictionary, url: fileUrl)
        }
        progress = handleProgress(progress: progress, total: 9, step: 4, progressHandler: progressHandler)
        emails.forEach { (email) in
            email.toDictionaryLabels(emailsMap: dispatchedEmails).forEach({ (emailLabelDictionary) in
                guard let jsonString = Utils.convertToJSONString(dictionary: emailLabelDictionary) else {
                    return
                }
                writeRowToFile(jsonRow: jsonString, url: fileUrl)
            })
        }
        progress = handleProgress(progress: progress, total: 5, step: 1, progressHandler: progressHandler)
        emails.map({$0.emailContacts}).flatMap({$0}).enumerated().forEach {
            guard let emailId = dispatchedEmails[$1.email.key] else {
                return
            }
            handleRow($1.toDictionary(id: $0 + 1, emailId: emailId, contactId: dispatchedContacts[$1.contact.email]!), url: fileUrl)
        }
        progress = handleProgress(progress: progress, total: 9, step: 6, progressHandler: progressHandler)
        var fileId = 1
        emails.forEach { (email) in
            email.files.enumerated().forEach({ (index, file) in
                guard let emailId = dispatchedEmails[file.emailId] else {
                    return
                }
                handleRow(file.toDictionary(id: fileId, emailId: emailId), url: fileUrl)
                fileId += 1
            })
        }
        progress = handleProgress(progress: progress, total: 9, step: 7, progressHandler: progressHandler)
        
        let results = DBManager.retrieveAliasesAndDomains(account: account)
        
        var aliasId = 1
        results.0.forEach {
            handleRow($0.toDictionary(id: aliasId), url: fileUrl)
            aliasId += 1
        }
        progress = handleProgress(progress: progress, total: 9, step: 8, progressHandler: progressHandler)
        var customDomainId = 1
        results.1.forEach {
            handleRow($0.toDictionary(id: customDomainId), url: fileUrl)
            customDomainId += 1
        }
        
        return (fileUrl, emails.map({$0.key}))
    }
    
    private func createDBFile(emailKeys: [Int], progressHandler: @escaping ((Int, Stage) -> Void)) -> (Error?, URL?){
        let fileUrl = FileUtils.getBackupUrl(name: "complete.db", folder: backupFolder)
        
        var contacts = [String: Int]()
        var emails = [Int: Int]()
        
        let account = DBManager.getAccountById(self.accountId)
        let results = DBManager.retrieveWholeDB(account: account!, emailKeys: emailKeys)
        var progress = handleProgress(progress: 0, total: results.total, step: results.step, progressHandler: progressHandler)
        
        let metadata = LinkFileHeaderData(recipientId: account!.username, domain: account!.domain ?? Env.plainDomain)
        metadata.fillFromAccount(account!)
        metadata.darkTheme = CriptextDefaults().themeMode == "Dark"
        metadata.language = Env.language
        
        handleRow(metadata.toDictionary(), url: fileUrl)
        results.contacts.enumerated().forEach {
            contacts[$1.email] = $0 + 1
            let dictionary = $1.toDictionary(id: $0 + 1)
            handleRow(dictionary, url: fileUrl)
            progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
        }
        results.labels.forEach {
            handleRow($0.toDictionary(), url: fileUrl)
            progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
        }
        results.emails.enumerated().forEach {
            emails[$1.key] = $0 + 1
            let dictionary = $1.toDictionary(
                id: $0 + 1,
                emailBody: FileUtils.getBodyFromFile(account: account!, metadataKey: "\($1.key)"),
                headers: FileUtils.getHeaderFromFile(account: account!, metadataKey: "\($1.key)"))
            handleRow(dictionary, url: fileUrl)
            progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
        }
        results.emails.forEach { (email) in
            email.toDictionaryLabels(emailsMap: emails).forEach({ (emailLabelDictionary) in
                guard let jsonString = Utils.convertToJSONString(dictionary: emailLabelDictionary) else {
                    return
                }
                writeRowToFile(jsonRow: jsonString, url: fileUrl)
                progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
            })
        }
        results.emailContacts.enumerated().forEach {
            guard let emailId = emails[$1.email.key] else {
                return
            }
            handleRow($1.toDictionary(id: $0 + 1, emailId: emailId, contactId: contacts[$1.contact.email]!), url: fileUrl)
            progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
        }
        var fileId = 1
        results.emails.forEach { (email) in
            email.files.enumerated().forEach({ (index, file) in
                guard let emailId = emails[file.emailId] else {
                    return
                }
                handleRow(file.toDictionary(id: fileId, emailId: emailId), url: fileUrl)
                progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
                fileId += 1
            })
        }
        
        return (nil, fileUrl)
    }
    
    private func handleRow(_ row: [String: Any], url: URL, appendNewLine: Bool = true){
        guard let jsonString = Utils.convertToJSONString(dictionary: row) else {
            return
        }
        writeRowToFile(jsonRow: jsonString, url: url, appendNewLine: appendNewLine)
    }
    
    private func writeRowToFile(jsonRow: String, url: URL, appendNewLine: Bool = true){
        let rowData = "\(jsonRow)\(appendNewLine ? "\n" : "")".data(using: .utf8)!
        if FileManager.default.fileExists(atPath: url.path) {
            let fileHandle = try! FileHandle(forUpdating: url)
            fileHandle.seekToEndOfFile()
            fileHandle.write(rowData)
            fileHandle.closeFile()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try! rowData.write(to: url, options: .atomic)
        }
    }
    
    private func handleProgress(progress: Int, total: Int, step: Int, progressHandler: @escaping ((Int, Stage) -> Void)) -> Int {
        let newProgress = progress + 1
        guard step > 0 else {
            DispatchQueue.main.async {
                progressHandler(newProgress * 100 / total, self.stage)
            }
            return newProgress
        }
        guard newProgress % step == 0 else {
            return newProgress
        }
        DispatchQueue.main.async {
            progressHandler(newProgress * 100 / total, self.stage)
        }
        return newProgress
    }
}
