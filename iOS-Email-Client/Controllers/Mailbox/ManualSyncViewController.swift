//
//  ManualSyncViewController.swift
//  iOS-Email-Client
//
//  Created by Allisson on 12/13/18.
//  Copyright © 2018 Criptext Inc. All rights reserved.
//

import Foundation

class ManualSyncViewController: UIViewController {
    
    let PROGRESS_WAITING = 10.0
    let PROGRESS_ACCEPT = 20.0
    let PROGRESS_DOWNLOADING_MAILBOX = 70.0
    let PROGRESS_PROCESSING_FILE = 80.0
    let PROGRESS_COMPLETE = 100.0
    @IBOutlet var connectUIView: ConnectUIView!
    
    var linkData: LoginDeviceViewController.LinkAccept?
    var socket : SingleWebSocket?
    var scheduleWorker = ScheduleWorker(interval: 10.0, maxRetries: 18)
    var state: ConnectionState = .initialize
    var myAccount: Account!
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
    }
    
    internal struct LinkSuccessData {
        var key: String
        var address: String
    }
    
    internal enum ConnectionState{
        case initialize
        case waitingConfirmation
        case waitingDB
        case downloadDB(LinkSuccessData)
        case unpackDB(String, LinkSuccessData)
        case processDB(String, LinkSuccessData)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        socket = SingleWebSocket()
        socket?.delegate = self
        connectUIView.initialLoad(email: "\(myAccount.username)\(Constants.domain)")
        scheduleWorker.delegate = self
        connectUIView.goBack = {
            self.goBack()
        }
        
        handleState()
    }
    
    func handleState(){
        switch(state){
        case .initialize:
            initializeSync()
        case .waitingConfirmation, .waitingDB:
            break
        case .downloadDB(let successData):
            handleAddress(data: successData)
        case .unpackDB(let path, let successData):
            unpackDB(path: path, data: successData)
        case .processDB(let path, let successData):
            restoreDB(path: path, data: successData)
        }
    }
    
    func goBack(){
        socket?.close()
        scheduleWorker.cancel()
        dismiss(animated: true, completion: nil)
    }
    
    func initializeSync(){
        APIManager.syncBegin(account: myAccount) { [weak self] (responseData) in
            guard case .Success = responseData,
                let weakSelf = self else {
                self?.handleState()
                return
            }
            weakSelf.connectUIView.progressChange(value: weakSelf.PROGRESS_WAITING, message: String.localize("Waiting for other devices"), completion: {})
            weakSelf.state = .waitingConfirmation
            weakSelf.handleState()
        }
    }
    
    func handleAddress(data: LinkSuccessData) {
        DBManager.clearMailbox()
        APIManager.downloadLinkDBFile(address: data.address, token: myAccount.jwt, progressCallback: { (progress) in
            self.connectUIView.progressChange(value: self.PROGRESS_ACCEPT + (self.PROGRESS_DOWNLOADING_MAILBOX - self.PROGRESS_ACCEPT) * progress, message: String.localize("Downloading Mailbox"), completion: {})
        }) { (responseData) in
            guard case let .SuccessString(filepath) =  responseData else {
                self.presentProcessInterrupted()
                return
            }
            self.state = .unpackDB(filepath, data)
            self.handleState()
        }
    }
    
    func unpackDB(path: String, data: LinkSuccessData) {
        self.connectUIView.progressChange(value: PROGRESS_PROCESSING_FILE, message: String.localize("Decrypting Mailbox"), completion: {})
        guard let linkAcceptData = self.linkData,
            let keyData = Data(base64Encoded: data.key),
            let decryptedKey = SignalHandler.decryptData(keyData, messageType: .preKey, account: myAccount, recipientId: myAccount.username, deviceId: linkAcceptData.authorizerId),
            let decryptedPath = AESCipher.streamEncrypt(path: path, outputName: StaticFile.decryptedDB.name, keyData: decryptedKey, ivData: nil, operation: kCCDecrypt),
            let decompressedPath = try? AESCipher.compressFile(path: decryptedPath, outputName: StaticFile.unzippedDB.name, compress: false) else {
                self.presentProcessInterrupted()
                return
        }
        CriptextFileManager.deleteFile(path: path)
        CriptextFileManager.deleteFile(path: decryptedPath)
        state = .processDB(decompressedPath, data)
        self.handleState()
    }
    
    func restoreDB(path: String, data: LinkSuccessData) {
        let queue = DispatchQueue(label: "com.email.loaddb", qos: .background, attributes: .concurrent)
        queue.async {
            let streamReader = StreamReader(url: URL(fileURLWithPath: path), delimeter: "\n", encoding: .utf8, chunkSize: 1024)
            var dbRows = [[String: Any]]()
            var progress = 80
            var maps = DBManager.LinkDBMaps.init(emails: [Int: Int](), contacts: [Int: String]())
            while let line = streamReader?.nextLine() {
                guard let row = Utils.convertToDictionary(text: line) else {
                    continue
                }
                dbRows.append(row)
                if dbRows.count >= 30 {
                    DBManager.insertBatchRows(rows: dbRows, maps: &maps)
                    dbRows.removeAll()
                    if progress < 99 {
                        progress += 1
                    }
                    DispatchQueue.main.async {
                        self.connectUIView.progressChange(value: Double(progress), message: nil, completion: {})
                    }
                }
            }
            DBManager.insertBatchRows(rows: dbRows, maps: &maps)
            CriptextFileManager.deleteFile(path: path)
            DispatchQueue.main.async {
                self.connectUIView.progressChange(value: self.PROGRESS_COMPLETE, message: String.localize("Decrypting Mailbox")) {
                    self.connectUIView.messageLabel.text = String.localize("Mailbox restored successfully!")
                }
            }
        }
    }
    
    func presentProcessInterrupted(){
        let retryPopup = GenericDualAnswerUIPopover()
        retryPopup.initialMessage = String.localize("Looks like you're having connection issues. Would you like to retry Mailbox Sync")
        retryPopup.initialTitle = String.localize("Sync Interrupted")
        retryPopup.leftOption = String.localize("Cancel")
        retryPopup.rightOption = String.localize("Retry")
        retryPopup.onResponse = { accept in
            guard accept else {
                self.goBack()
                return
            }
            self.handleState()
        }
        self.presentPopover(popover: retryPopup, height: 235)
    }
    
    func onDenied() {
        let deniedPopup = GenericAlertUIPopover()
        deniedPopup.myTitle = "Sync Denied"
        deniedPopup.myMessage = "Your request to sync mailbox was denied by one of your other devices"
        deniedPopup.onOkPress = { [weak self] in
            self?.goBack()
        }
    }
    
    func onAccept(linkData: LoginDeviceViewController.LinkAccept) {
        self.linkData = linkData
        state = .waitingDB
        self.connectUIView.progressChange(value: PROGRESS_ACCEPT, message: String.localize("Waiting for Mailbox"), completion: {})
        handleState()
    }
}

extension ManualSyncViewController: ScheduleWorkerDelegate {
    func work(completion: @escaping (Bool) -> Void) {
        switch(self.state) {
        case .waitingConfirmation:
            APIManager.getSyncStatus(account: myAccount) { (responseData) in
                guard case let .SuccessDictionary(event) = responseData,
                    let eventString = event["params"] as? String,
                    let eventParams = Utils.convertToDictionary(text: eventString) else {
                        completion(false)
                        return
                }
                completion(true)
                self.newMessage(cmd: Event.Link.syncAccept.rawValue, params: eventParams)
            }
        case .waitingDB:
            APIManager.getLinkData(token: myAccount.jwt) { (responseData) in
                guard case let .SuccessDictionary(event) = responseData,
                    let eventString = event["params"] as? String,
                    let eventParams = Utils.convertToDictionary(text: eventString) else {
                        completion(false)
                        return
                }
                completion(true)
                self.newMessage(cmd: Event.Link.syncSuccess.rawValue, params: eventParams)
            }
        default:
            break
        }
    }
    
    func dangled() {
        let retryPopup = GenericDualAnswerUIPopover()
        retryPopup.initialMessage = String.localize("Something has happened that is delaying this process. Do you want to continue waiting?")
        retryPopup.initialTitle = String.localize("Well, that’s odd…")
        retryPopup.onResponse = { accept in
            guard accept else {
                self.goBack()
                return
            }
            self.scheduleWorker.start()
        }
        self.presentPopover(popover: retryPopup, height: 205)
    }
}

extension ManualSyncViewController: SingleSocketDelegate {
    func newMessage(cmd: Int32, params: [String : Any]?) {
        switch(cmd){
        case Event.Link.syncAccept.rawValue:
            guard case .waitingConfirmation = state,
                let deviceId = params?["deviceId"] as? Int,
                let name = params?["name"] as? String,
                let authorizerId = params?["authorizerId"] as? Int32,
                let authorizerName = params?["authorizerName"] as? String,
                let authorizerType = params?["authorizerType"] as? Int else {
                    break
            }
            let linkData = LoginDeviceViewController.LinkAccept(deviceId: deviceId, name: name, authorizerId: authorizerId, authorizerName: authorizerName, authorizerType: authorizerType)
            self.onAccept(linkData: linkData)
        case Event.Link.syncDeny.rawValue:
            guard case .waitingConfirmation = state else {
                return
            }
            self.onDenied()
        case Event.Link.syncSuccess.rawValue:
            guard let address = params?["dataAddress"] as? String,
                let key = params?["key"] as? String else {
                    break
            }
            scheduleWorker.cancel()
            let data = LinkSuccessData(key: key, address: address)
            state = .downloadDB(data)
            handleState()
        default:
            break
        }
    }
}
