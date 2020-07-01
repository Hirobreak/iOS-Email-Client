//
//  BackupDBManager.swift
//  iOS-Email-Client
//
//  Created by Pedro Iniguez on 6/26/20.
//  Copyright © 2020 Criptext Inc. All rights reserved.
//

import Foundation
import SwiftyJSON
import RealmSwift

class BackupDBManager {
    
    static let PAGINATION_SIZE = 5;
    let realm = try! Realm()
    
    func getThreads(from label: Int, since date:Date, limit: Int = PAGINATION_SIZE, threadIds: [String] = [], account: Account) -> [Email] {
        var threadEmails = [Email]()
        autoreleasepool {
            let emailsLimit = limit == 0 ? BackupDBManager.PAGINATION_SIZE : limit
            let predicate = NSPredicate(format: "account.compoundKey == %@ AND date < %@", account.compoundKey, date as NSDate)
            let emails = realm.objects(Email.self).filter(predicate).sorted(byKeyPath: "date", ascending: false).distinct(by: ["threadId"])
            threadEmails = customDistinctEmailThreads(emails: emails, label: label, limit: emailsLimit, threadIds: threadIds, myEmail: account.email)
        }
        return threadEmails
    }
    
    private func customDistinctEmailThreads(emails: Results<Email>, label: Int, limit: Int, threadIds: [String] = [], myEmail: String) -> [Email] {
        var myEmails = [Email]()
        var myThreadIds = Set<String>(threadIds)
        for email in emails {
            guard myThreadIds.count < limit else {
                break
            }
            guard !myThreadIds.contains(email.threadId) else {
                continue
            }
            let predicate = NSPredicate(format: "threadId = %@ AND account.compoundKey == %@", email.threadId, email.account.compoundKey)
            let threadEmails = realm.objects(Email.self).filter(predicate).sorted(byKeyPath: "date", ascending: true)
            guard !threadEmails.isEmpty else {
                continue
            }
            myEmails.append(contentsOf: threadEmails)
            myThreadIds.insert(email.threadId)
        }
        return myEmails
    }
}
