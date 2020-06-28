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

class CreateCustomJSONFileAsyncTask {
    
    enum Kind {
        case link
        case backup
        case share
        
        var url: URL {
            switch(self){
            case .link:
                return StaticFile.emailDB.url
            case .backup:
                return StaticFile.backupDB.url
            case .share:
                return StaticFile.shareDB.url
            }
        }
    }
    
    init(accountId: String, kind: Kind = .link) {
        self.accountId = accountId
        self.fileURL = kind.url
    }
    
    let fileURL: URL
    var contacts = [String: Int]()
    var emails = [Int: Int]()
    var accountId: String
    
    func start(progressHandler: @escaping ((Int) -> Void), completion: @escaping ((Error?, URL?) -> Void)){
        try? FileManager.default.removeItem(at: fileURL)
        DispatchQueue.global().async {
            let initialDB = self.createInitialDBFile()
            let result = self.createDBFile(progressHandler: progressHandler)
            
            DispatchQueue.main.async {
                completion(result.0, result.1)
            }
        }
    }
    
    private func createInitialDBFile() -> [Int] {
        let account = DBManager.getAccountById(self.accountId)
        
        let backupDBManager = BackupDBManager()
        
        let emails = backupDBManager.getThreads(from: SystemLabel.inbox.id, since: Date(), account: account!)
        
        var dispatchedContacts = [String: Int]()
        var dispatchedLabels = [String: Int]()
        var dispatchedEmails = [Int: Int]()
        
        emails.map({$0.getContacts()}).flatMap({$0}).enumerated().forEach {
            guard dispatchedContacts[$1.email] == nil else {
                return
            }
            dispatchedContacts[$1.email] = $0 + 1
            handleRow($1.toDictionary(id: $0 + 1))
        }
        emails.map({$0.labels}).flatMap({$0}).enumerated().forEach {
            guard dispatchedLabels[$1.uuid] == nil && SystemLabel(rawValue: $1.id) == nil  else {
                return
            }
            dispatchedLabels[$1.uuid] = $0 + 1
            handleRow($1.toDictionary())
        }
        emails.enumerated().forEach {
            dispatchedEmails[$1.key] = $0 + 1
            let dictionary = $1.toDictionary(
                id: $0 + 1,
                emailBody: FileUtils.getBodyFromFile(account: account!, metadataKey: "\($1.key)"),
                headers: FileUtils.getHeaderFromFile(account: account!, metadataKey: "\($1.key)"))
            handleRow(dictionary)
        }
    }
    
    private func createDBFile(progressHandler: @escaping ((Int) -> Void)) -> (Error?, URL?){
        let account = DBManager.getAccountById(self.accountId)
        let results = DBManager.retrieveWholeDB(account: account!)
        var progress = handleProgress(progress: 0, total: results.total, step: results.step, progressHandler: progressHandler)
        
        let metadata = LinkFileHeaderData(recipientId: account!.username, domain: account!.domain ?? Env.plainDomain)
        metadata.fillFromAccount(account!)
        metadata.darkTheme = CriptextDefaults().themeMode == "Dark"
        metadata.language = Env.language
        
        handleRow(metadata.toDictionary())
        results.contacts.enumerated().forEach {
            contacts[$1.email] = $0 + 1
            let dictionary = $1.toDictionary(id: $0 + 1)
            handleRow(dictionary)
            progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
        }
        results.labels.forEach {
            handleRow($0.toDictionary())
            progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
        }
        results.emails.enumerated().forEach {
            emails[$1.key] = $0 + 1
            let dictionary = $1.toDictionary(
                id: $0 + 1,
                emailBody: FileUtils.getBodyFromFile(account: account!, metadataKey: "\($1.key)"),
                headers: FileUtils.getHeaderFromFile(account: account!, metadataKey: "\($1.key)"))
            handleRow(dictionary)
            progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
        }
        results.emails.forEach { (email) in
            email.toDictionaryLabels(emailsMap: emails).forEach({ (emailLabelDictionary) in
                guard let jsonString = Utils.convertToJSONString(dictionary: emailLabelDictionary) else {
                    return
                }
                writeRowToFile(jsonRow: jsonString)
                progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
            })
        }
        results.emailContacts.enumerated().forEach {
            guard let emailId = emails[$1.email.key] else {
                return
            }
            handleRow($1.toDictionary(id: $0 + 1, emailId: emailId, contactId: contacts[$1.contact.email]!))
            progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
        }
        var fileId = 1
        results.emails.forEach { (email) in
            email.files.enumerated().forEach({ (index, file) in
                guard let emailId = emails[file.emailId] else {
                    return
                }
                handleRow(file.toDictionary(id: fileId, emailId: emailId))
                progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
                fileId += 1
            })
        }
        var aliasId = 1
        results.aliases.forEach {
            handleRow($0.toDictionary(id: aliasId))
            progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
            aliasId += 1
        }
        var customDomainId = 1
        results.customDomains.forEach {
            handleRow($0.toDictionary(id: customDomainId))
            progress = handleProgress(progress: progress, total: results.total, step: results.step, progressHandler: progressHandler)
            customDomainId += 1
        }
        
        return (nil, self.fileURL)
    }
    
    private func handleRow(_ row: [String: Any], appendNewLine: Bool = true){
        guard let jsonString = Utils.convertToJSONString(dictionary: row) else {
            return
        }
        writeRowToFile(jsonRow: jsonString, appendNewLine: appendNewLine)
    }
    
    private func writeRowToFile(jsonRow: String, appendNewLine: Bool = true){
        let rowData = "\(jsonRow)\(appendNewLine ? "\n" : "")".data(using: .utf8)!
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let fileHandle = try! FileHandle(forUpdating: fileURL)
            fileHandle.seekToEndOfFile()
            fileHandle.write(rowData)
            fileHandle.closeFile()
        } else {
            try! rowData.write(to: fileURL, options: .atomic)
        }
    }
    
    private func handleProgress(progress: Int, total: Int, step: Int, progressHandler: @escaping ((Int) -> Void)) -> Int {
        let newProgress = progress + 1
        guard step > 0 else {
            DispatchQueue.main.async {
                progressHandler(newProgress * 100 / total)
            }
            return newProgress
        }
        guard newProgress % step == 0 else {
            return newProgress
        }
        DispatchQueue.main.async {
            progressHandler(newProgress * 100 / total)
        }
        return newProgress
    }
}
