//
//  APIManager.swift
//  Criptext Secure Email
//
//  Created by Gianni Carlo on 2/16/17.
//  Copyright © 2017 Criptext, Inc. All rights reserved.
//

import Foundation
import SwiftyJSON
import Alamofire
import GoogleAPIClientForREST
import MonkeyKit
import RealmSwift

protocol ProgressDelegate {
    func updateProgress(_ percent:Double, for id:String)
}

class APIManager {
    static let baseUrl = "http://172.30.1.47:8000"
    
    static let CODE_SUCESS = 0
    static let CODE_JWT_INVALID = 101
    static let CODE_SESSION_INVALID = 102
    static let CODE_FILE_SIZE_EXCEEDED = 413
    static let CODE_REQUEST_CANCELLED = -999
    
    static let reachabilityManager = Alamofire.NetworkReachabilityManager()!
    
    class func singUpRequest(_ params: [String : Any], completion: @escaping ((Error?, String?) -> Void)){
        let url = "\(self.baseUrl)/user"
        
        Alamofire.request(url, method: .post, parameters: params, encoding: JSONEncoding.default).responseString{
            (response) in
            guard let value = response.result.value else {
                completion(response.result.error, nil)
                return
            }
            completion(nil, value)
        }
    }
    
    class func loginRequest(_ username: String, _ password: String, completion: @escaping ((Error?, String?) -> Void)){
        let parameters = ["username": username,
                          "password": password,
                          "deviceId": 1] as [String : Any]
        let url = "\(self.baseUrl)/user/auth"
        Alamofire.request(url, method: .post, parameters: parameters, encoding: JSONEncoding.default).responseString{
            (response) in
            guard let value = response.result.value else {
                completion(response.result.error, nil)
                return
            }
            completion(nil, value)
        }
    }
    
    class func sendKeysRequest(_ params: [String : Any], token: String, completion: @escaping ((Error?) -> Void)){
        let url = "\(self.baseUrl)/keybundle"
        let headers = ["Authorization": "Bearer \(token)"]
        Alamofire.request(url, method: .post, parameters: params, encoding: JSONEncoding.default, headers: headers).responseString { response in
            response.result.ifFailure {
                completion(response.result.error)
                return
            }
            completion(nil)
        }
    }
    
    class func getKeysRequest(recipientId: String, deviceId: String, token: String, completion: @escaping ((Error?, Any?) -> Void)){
        let url = "\(self.baseUrl)/keybundle/\(recipientId)/\(deviceId)"
        let headers = ["Authorization": "Bearer \(token)"]
        Alamofire.request(url, method: .get, encoding: JSONEncoding.default, headers: headers).responseJSON { response in
            switch(response.result) {
                case .success(let value):
                    completion(nil, value)
                    break
                case .failure(let error):
                    completion(error, nil)
                    break;
            }
        }
    }
    
    class func postMailRequest(_ params: [String : Any], token: String, completion: @escaping ((Error?) -> Void)){
        let url = "\(self.baseUrl)/email"
        let headers = ["Authorization": "Bearer \(token)"]
        Alamofire.request(url, method: .post, parameters: params, encoding: JSONEncoding.default, headers: headers).responseString { response in
            response.result.ifFailure {
                completion(response.result.error)
                return
            }
            completion(nil)
        }
    }
    
    /*
       Get specified number of apps from itunes endpoint
     */
    class func connect(
        _ mail:String,
        firstName:String,
        lastName:String,
        serverToken:String,
        completion: @escaping ((Error?, User?) -> Void)
        ){
        
        let lang = Locale.current.languageCode ?? "en"
        
        let parameters = ["first_name": firstName,
                          "last_name": lastName,
                          "server_token": serverToken,
                          "lang": lang,
                          "device": UIDevice.current.identifierForVendor!.uuidString] as [String : Any]
        
        print(parameters)
        let url = "\(self.baseUrl)/v2.0/user/session/\(mail)/create"
        
        Alamofire.request(url, method: .post, parameters: parameters, encoding: JSONEncoding.default)
            .responseJSON { (response) in
                
                guard let value = response.result.value else {
                    completion(response.error, nil)
                    return
                }
                
                let jsonVar = JSON(value)
                
                let errorCode = jsonVar["error"].intValue
                
                guard errorCode == self.CODE_SUCESS else {
                    print("error")
                    
                    completion(NSError(domain: "com.criptext.com", code: errorCode, userInfo: nil), nil)
                    return
                }
                
                let auth = jsonVar["auth"].stringValue
                let jwt = jsonVar["jwt"].stringValue
                let session = jsonVar["session"].stringValue
                let pubKey = jsonVar["pub_key"].stringValue
                
                let id = jsonVar["user"]["id"].intValue
                let status = jsonVar["user"]["status"].intValue
                let monkeyId = jsonVar["user"]["monkey_id"].stringValue
                let coupon = jsonVar["user"]["coupon"].stringValue
                let header = jsonVar["user"]["header"].stringValue
                let billings = jsonVar["user"]["billing_infos"].arrayValue
                
                guard let data = Data(base64Encoded: pubKey), let pubKeyDecoded = String(data: data, encoding: .utf8) else {
                    completion(NSError(domain: "com.criptext.com", code: errorCode, userInfo: nil), nil)
                    return
                }
                
                let user = User()
                user.id = id
                user.auth = auth
                user.status = status
                user.monkeyId = monkeyId
                user.coupon = coupon
                user.jwt = jwt
                user.session = session
                user.pubKey = pubKeyDecoded
                user.emailHeader = header
                
                if let billing = billings.first, let plan = billing["plan"].string {
                    user.plan = plan
                } else {
                    user.plan = "Free trial"
                }
                
                print(jsonVar)
                completion(nil, user)
        }
    }
    
    class func request(_ user:User, url:String, method:HTTPMethod, parameters:Parameters?, headers:HTTPHeaders?, completion:@escaping (DataResponse<String>) -> Void){
        
        if let parameters = parameters {
            //try the request
            Alamofire.request(url, method: method, parameters: parameters, encoding: JSONEncoding.default, headers: headers).responseString { (response) in
                
                
                if let value = response.result.value,
                    let dataFromString = value.data(using: .utf8, allowLossyConversion: false) {
                    let jsonVar = try! JSON(data: dataFromString)
                    
                    let errorCode = jsonVar["error"].intValue
                    
                    //check if it failed due to jwt expired or wrong session
                    if errorCode == CODE_JWT_INVALID || errorCode == CODE_SESSION_INVALID {
                        //auth request
                        
                        self.connect(user.email,
                                     firstName: user.firstName,
                                     lastName: user.lastName,
                                     serverToken: user.serverAuthCode,
                                     completion: { (error, userResponse) in
                                        
                                        //if auth failed, return failed to the original request
                                        guard let value = response.result.value else {
                                            completion(response)
                                            return
                                        }
                                        
                                        let jsonVar = JSON(value)
                                        let errorCode = jsonVar["error"].intValue
                                        
                                        guard errorCode == self.CODE_SUCESS else {
                                            print("Error auth")
                                            completion(response)
                                            return
                                        }
                                        
                                        //if auth ok, retry original request
                                        user.jwt = userResponse!.jwt
                                        
                                        self.request(user, url: url, method: method, parameters: parameters, headers: ["Authorization":user.jwt], completion: completion)
                        })
                        return
                    }
                }
                
                //return success to original request
                completion(response)
            }
            return
        }
        
        //try the request
        Alamofire.request(url, method: method, encoding: JSONEncoding.default, headers: headers).responseString { (response) in
            
            if let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false) {
                let jsonVar = try! JSON(data: dataFromString)
                
                let errorCode = jsonVar["error"].intValue
                //check if it failed due to jwt expired or wrong session
                if errorCode == CODE_JWT_INVALID || errorCode == CODE_SESSION_INVALID {
                    
                    self.connect(user.email,
                                 firstName: user.firstName,
                                 lastName: user.lastName,
                                 serverToken: user.serverAuthCode,
                                 completion: { (error, userResponse) in
                                    
                                    //if auth failed, return failed to the original request
                                    if let _ = error {
                                        completion(response)
                                        return
                                    }
                                    
                                    DBManager.update(user, jwt: userResponse!.jwt)
                                    DBManager.update(user, session: userResponse!.session)
                                    
                                    var urlComponents = url.components(separatedBy: "&").filter{ !$0.contains("session_token=")}
                                    
                                    urlComponents.append("session_token=\(user.session)")
                                    
                                    let newUrl = urlComponents.joined(separator: "&")
                                    
                                    print(newUrl)
                                    self.request(user, url: newUrl, method: method, parameters: parameters, headers: ["Authorization":user.jwt], completion: completion)
                    })
                    return
                }
            }
            
            
            //return to original request
            completion(response)
        }
    }
    
    class func getActivityPanel(_ user:User, since:Int, count:String, completion: @escaping ((Error?, ([Activity], [AttachmentCriptext])?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/user/\(user.id)/emails/attachments/since?from=\(since)&count=\(count)&email=\(user.email)&device=\(UIDevice.current.identifierForVendor!.uuidString)&session_token=\(user.session)"
        
        let headers = ["Authorization": user.jwt]
        
        self.request(user, url: url, method: .get, parameters: nil, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false) else {
                completion(response.error, nil)
                return
            }
            
            let jsonVar = try! JSON(data: dataFromString)
            
            let errorCode = jsonVar["error"].intValue
            
            guard errorCode == self.CODE_SUCESS else {
                print("error")
                
                completion(NSError(domain: "com.criptext.com", code: errorCode, userInfo: nil), nil)
                return
            }
            
            var activityArray = [Activity]()
            let activityArrayResponse = jsonVar["resp"].arrayValue
            
            for activityObject in activityArrayResponse {
                let activity = Activity()
                
                activity.token = activityObject["token"].stringValue
                activity.to = activityObject["to"].stringValue
                activity.toDisplayString = self.parseDisplayString(activity.to)
                activity.subject = activityObject["subject"].stringValue
                activity.type = activityObject["tipo"].intValue
                activity.exists = activityObject["exists"].intValue == 1
                activity.isNew = activityObject["isnew"].intValue == 1
                activity.secondsSet = activityObject["secondsSet"].intValue
                activity.timestamp = activityObject["timestamp"].intValue
                
                let muted = activityObject["ismuted"].string ?? "0"
                activity.isMuted = muted == "1"
                
                activity.recallTime = Int(Double(activityObject["recallTime"].stringValue) ?? 0)
                
                let openString = activityObject["openlocations"].rawString(.utf8, options: .prettyPrinted) ?? "[]"
                
                activity.openArraySerialized = openString
                activity.openArray = JSON(parseJSON: openString).arrayValue.map({$0.stringValue})
                
                activity.openArray = activityObject["openlocations"].arrayValue.map({$0.stringValue})
                
                activityArray.append(activity)
            }
            
            var attachmentArray = [AttachmentCriptext]()
            let attachmentArrayResponse = jsonVar["attach"].arrayValue
            
            for attachmentObject in attachmentArrayResponse {
                let attachment = AttachmentCriptext()
                
                attachment.userId = attachmentObject["info"]["user_id"].stringValue
                attachment.fileName = attachmentObject["info"]["file_name"].stringValue
                attachment.mimeType = mimeTypeForPath(path: attachment.fileName)
                attachment.fileToken = attachmentObject["info"]["file_token"].stringValue
                attachment.fileType = attachmentObject["info"]["file_type"].stringValue
                attachment.size = Int(attachmentObject["info"]["file_size"].stringValue) ?? 0
                attachment.currentPassword = attachmentObject["info"]["password"].stringValue
                attachment.isReadOnly = attachmentObject["info"]["read_only"].boolValue
                attachment.remoteUrl = attachmentObject["info"]["remote_url"].stringValue
                attachment.timestamp = attachmentObject["info"]["timestamp"].stringValue
                attachment.emailToken = attachmentObject["info"]["token"].stringValue
                attachment.isUploaded = true
                
                let openString = attachmentObject["opens"].rawString(.utf8, options: .prettyPrinted) ?? "[]"
                
                attachment.openArraySerialized = openString
                attachment.openArray = JSON(parseJSON: openString).arrayValue.map({$0.stringValue})
                attachment.openArray = attachmentObject["opens"].arrayValue.map({$0.stringValue})
                
                let downloadString = attachmentObject["downloads"].rawString(.utf8, options: .prettyPrinted) ?? "[]"
                
                attachment.downloadArraySerialized = downloadString
                attachment.downloadArray = JSON(parseJSON: downloadString).arrayValue.map({$0.stringValue})
                attachment.downloadArray = attachmentObject["downloads"].arrayValue.map({$0.stringValue})
                
                attachmentArray.append(attachment)
            }
            
            completion(nil, (activityArray, attachmentArray))
        }
    }
    
    class func update(_ header:String, of user:User, completion: @escaping ((Error?, String?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/user/\(user.email)/settings/update/header"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        
        let parameters = ["header":header]
        
        self.request(user, url: url, method: .post, parameters: parameters, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false) else {
                completion(response.error, nil)
                return
            }
            
            let jsonVar = try! JSON(data: dataFromString)
            
            let errorCode = jsonVar["error"].intValue
            
            guard errorCode == self.CODE_SUCESS else {
                print("error")
                
                completion(NSError(domain: "com.criptext.com", code: errorCode, userInfo: nil), nil)
                return
            }
            
            completion(nil, header)
        }
    }
    
    class func getHeader(_ user:User, completion: @escaping ((Error?, String?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/user/\(user.email)/settings/get/header"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        
        self.request(user, url: url, method: .get, parameters: nil, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false) else {
                completion(response.error, nil)
                return
            }
            
            let jsonVar = try! JSON(data: dataFromString)
            
            let errorCode = jsonVar["error"].intValue
            
            guard errorCode == self.CODE_SUCESS else {
                print("error")
                
                completion(NSError(domain: "com.criptext.com", code: errorCode, userInfo: nil), nil)
                return
            }
            
            let header = jsonVar["resp"].stringValue
            
            completion(nil, header)
        }
    }
    
    class func getCoupon(_ user:User, completion: @escaping ((Error?, String?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/user/coupon?email=\(user.email)"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        
        self.request(user, url: url, method: .get, parameters: nil, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false) else {
                completion(response.error, nil)
                return
            }
            
            let jsonVar = try! JSON(data: dataFromString)
            
            let errorCode = jsonVar["error"].intValue
            
            guard errorCode == self.CODE_SUCESS else {
                print("error")
                
                completion(NSError(domain: "com.criptext.com", code: errorCode, userInfo: nil), nil)
                return
            }
            
            let coupon = jsonVar["resp"].stringValue
            
            completion(nil, coupon)
        }
    }
    
    class func unsendMail(_ token:String, user:User, completion: @escaping ((Error?, String?) -> Void)){
        let url = "\(self.baseUrl)/v2.1/email/recall/\(token)/\(user.id)"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        
        self.request(user, url: url, method: .post, parameters: nil, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false) else {
                completion(response.error, nil)
                return
            }
            
            let jsonVar = try! JSON(data: dataFromString)
            
            let errorCode = jsonVar["error"].intValue
            
            guard errorCode == self.CODE_SUCESS else {
                print("error")
                
                completion(NSError(domain: "com.criptext.com", code: errorCode, userInfo: nil), nil)
                return
            }
            
            let token = jsonVar["token"].stringValue
            
            completion(nil, token)
        }
    }
    
    class func register(_ token:String, user:User, completion: @escaping ((Error?, String?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/user/\(user.email)/pushtoken/add"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        
        let device = GTLREncodeBase64(systemIdentifier().data(using: .utf8)) ?? systemIdentifier()
        let parameters = ["token": token,
                          "device": "ios",
                          "device_id": device]
        
        self.request(user, url: url, method: .post, parameters: parameters, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false) else {
                    completion(response.error, nil)
                    return
            }
            
            let jsonVar = try! JSON(data: dataFromString)
            
            let errorCode = jsonVar["error"].intValue
            
            guard errorCode == self.CODE_SUCESS else {
                print("error")
                
                completion(NSError(domain: "com.criptext.com", code: errorCode, userInfo: nil), nil)
                return
            }
            
            let token = jsonVar["resp"].stringValue
            
            completion(nil, token)
        }
    }
    
    class func unregisterToken(_ user:User, completion: @escaping ((Error?, String?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/user/\(user.email)/pushtoken/remove"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        
        let device = GTLREncodeBase64(systemIdentifier().data(using: .utf8)) ?? systemIdentifier()
        let parameters = ["device_id": device]
        
        self.request(user, url: url, method: .post, parameters: parameters, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false) else {
                    completion(response.error, nil)
                    return
            }
            
            let jsonVar = try! JSON(data: dataFromString)
            
            let errorCode = jsonVar["error"].intValue
            
            guard errorCode == self.CODE_SUCESS else {
                print("error")
                
                completion(NSError(domain: "com.criptext.com", code: errorCode, userInfo: nil), nil)
                return
            }
            
            let response = jsonVar["resp"].stringValue
            
            completion(nil, response)
        }
    }
    
    class func getMailDetail(_ user:User, token:String, completion: @escaping ((Error?, [AttachmentCriptext]?, Activity?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/email/get/\(token)/withattachments"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        
        self.request(user, url: url, method: .get, parameters: nil, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false) else {
                completion(response.error, nil, nil)
                return
            }
            
            let jsonVar = try! JSON(data: dataFromString)
            
            var attachmentArray = [AttachmentCriptext]()
            let attachments = jsonVar["attachments"].arrayValue
            
            for attachmentObject in attachments {
                
                let attachment = AttachmentCriptext()
                
                attachment.userId = attachmentObject["info"]["user_id"].stringValue
                attachment.fileName = attachmentObject["info"]["file_name"].stringValue
                attachment.mimeType = mimeTypeForPath(path: attachment.fileName)
                attachment.fileToken = attachmentObject["info"]["file_token"].stringValue
                attachment.fileType = attachmentObject["info"]["file_type"].stringValue
                attachment.size = Int(attachmentObject["info"]["file_size"].stringValue) ?? 0
                attachment.currentPassword = attachmentObject["info"]["password"].stringValue
                attachment.isReadOnly = attachmentObject["info"]["read_only"].boolValue
                attachment.remoteUrl = attachmentObject["info"]["remote_url"].stringValue
                attachment.timestamp = attachmentObject["info"]["timestamp"].stringValue
                attachment.emailToken = attachmentObject["info"]["token"].stringValue
                attachment.isUploaded = true
                
                let openString = attachmentObject["opens"].rawString(.utf8, options: .prettyPrinted) ?? "[]"
                
                attachment.openArraySerialized = openString
                attachment.openArray = JSON(parseJSON: openString).arrayValue.map({$0.stringValue})
                attachment.openArray = attachmentObject["opens"].arrayValue.map({$0.stringValue})
                
                let downloadString = attachmentObject["downloads"].rawString(.utf8, options: .prettyPrinted) ?? "[]"
                
                attachment.downloadArraySerialized = downloadString
                attachment.downloadArray = JSON(parseJSON: downloadString).arrayValue.map({$0.stringValue})
                attachment.downloadArray = attachmentObject["downloads"].arrayValue.map({$0.stringValue})
                
                attachmentArray.append(attachment)
            }

            guard let mail = jsonVar["mail"].dictionary else {
                completion(nil, attachmentArray, nil)
                return
            }
            let activity = Activity()
            
            activity.token = mail["token"]!.stringValue
            activity.to = mail["to"]!.stringValue
            activity.toDisplayString = self.parseDisplayString(activity.to)
            activity.subject = mail["subject"]!.stringValue
            activity.type = mail["tipo"]!.intValue
            activity.exists = mail["exists"]!.intValue == 1
            activity.isNew = mail["isnew"]!.intValue == 1
            activity.secondsSet = mail["secondsSet"]!.intValue
            
            let muted = mail["ismuted"]?.string ?? "0"
            activity.isMuted = muted == "1"
            
            activity.recallTime = Int(Double((mail["recallTime"] ?? "0").stringValue) ?? 0)
            activity.timestamp = mail["timestamp"]!.intValue
            
            let openString = mail["openlocations"]!.rawString(.utf8, options: .prettyPrinted) ?? "[]"
            activity.openArraySerialized = openString
            activity.openArray = JSON(parseJSON: openString).arrayValue.map({$0.stringValue})
            activity.openArray = mail["openlocations"]!.arrayValue.map({$0.stringValue})
            
            
            completion(nil, attachmentArray, activity)
        }
    }
    
    class func parseDisplayString(_ value:String) -> String{
        var toDisplayEmail = ""
        for tag in value.components(separatedBy: ",") {
            var copyTag = tag
            
            if let match = copyTag.range(of: " <[^ ]+", options: .regularExpression){
                
                copyTag.removeSubrange(match)
                
                if(toDisplayEmail == "") {
                    toDisplayEmail = copyTag
                }else{
                    toDisplayEmail = toDisplayEmail + "," + copyTag
                }
            }else {
                if(toDisplayEmail == "") {
                    toDisplayEmail = copyTag
                }else{
                    toDisplayEmail = toDisplayEmail + "," + copyTag
                }
            }
        }
        
        return toDisplayEmail
    }
    
    class func getMailDetails(_ user:User, tokens:[String], mark opens:[String], completion: @escaping ((Error?, [AttachmentCriptext]?, [Activity]?, [String:String]?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/emails/detail/withattachments"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        let parameters = ["tokens":tokens,
                          "opens": opens]
        
        self.request(user, url: url, method: .post, parameters: parameters, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false),
                let jsonArray = try! JSON(data: dataFromString).dictionaryValue["mails"]?.array else {
                    completion(response.error, nil, nil, nil)
                    return
            }
            
            var attachmentArray = [AttachmentCriptext]()
            
            var textHash = [String:String]()
            var activityArray = [Activity]()
            
            for jsonObject in jsonArray {
                
                let jsonVar = jsonObject.dictionaryValue
                
                guard let attachmentsObject = jsonVar["attachments"],
                    let mailObject = jsonVar["mail"] else {
                    return
                }
                
                let attachments = attachmentsObject.arrayValue
            
                for attachmentObject in attachments {
                
                    let attachment = AttachmentCriptext()
                    
                    attachment.userId = attachmentObject["info"]["user_id"].stringValue
                    attachment.fileName = attachmentObject["info"]["file_name"].stringValue
                    attachment.mimeType = mimeTypeForPath(path: attachment.fileName)
                    attachment.fileToken = attachmentObject["info"]["file_token"].stringValue
                    attachment.fileType = attachmentObject["info"]["file_type"].stringValue
                    attachment.size = Int(attachmentObject["info"]["file_size"].stringValue) ?? 0
                    attachment.currentPassword = attachmentObject["info"]["password"].stringValue
                    attachment.isReadOnly = attachmentObject["info"]["read_only"].boolValue
                    attachment.remoteUrl = attachmentObject["info"]["remote_url"].stringValue
                    attachment.timestamp = attachmentObject["info"]["timestamp"].stringValue
                    attachment.emailToken = attachmentObject["info"]["token"].stringValue
                    attachment.isUploaded = true
                
                    let openString = attachmentObject["opens"].rawString(.utf8, options: .prettyPrinted) ?? "[]"
                    
                    attachment.openArraySerialized = openString
                    attachment.openArray = JSON(parseJSON: openString).arrayValue.map({$0.stringValue})
                    attachment.openArray = attachmentObject["opens"].arrayValue.map({$0.stringValue})
                    
                    let downloadString = attachmentObject["downloads"].rawString(.utf8, options: .prettyPrinted) ?? "[]"
                    
                    attachment.downloadArraySerialized = downloadString
                    attachment.downloadArray = JSON(parseJSON: downloadString).arrayValue.map({$0.stringValue})
                    attachment.downloadArray = attachmentObject["downloads"].arrayValue.map({$0.stringValue})
                
                    attachmentArray.append(attachment)
                }
            
                let mail = mailObject.dictionaryValue
                
                if let token = mail["token"],
                    let to = mail["to"],
                    let subject = mail["subject"],
                    let type = mail["tipo"],
                    let exists = mail["exists"],
                    let isNew = mail["isnew"],
                    let secondsSet = mail["secondsSet"],
                    let timestamp = mail["timestamp"],
                    let openlocations = mail["openlocations"]{
                    
                    let activity = Activity()
                    
                    activity.token = token.stringValue
                    activity.to = to.stringValue
                    activity.toDisplayString = self.parseDisplayString(activity.to)
                    activity.subject = subject.stringValue
                    activity.type = type.intValue
                    activity.exists = exists.intValue == 1
                    activity.isNew = isNew.intValue == 1
                    activity.secondsSet = secondsSet.intValue
                    activity.timestamp = timestamp.intValue
                    
                    let muted = mail["ismuted"]?.string ?? "0"
                    activity.isMuted = muted == "1"
                    
                    activity.recallTime = Int(Double((mail["recallTime"] ?? "0").stringValue) ?? 0)
                    
                    let openString = openlocations.rawString(.utf8, options: .prettyPrinted) ?? "[]"
                    
                    activity.openArraySerialized = openString
                    activity.openArray = JSON(parseJSON: openString).arrayValue.map({$0.stringValue})
                    activity.openArray = openlocations.arrayValue.map({$0.stringValue})
                    
                    activityArray.append(activity)
                }
                
                if let text = mail["text"],
                    let token = mail["token"]{
                    textHash[token.stringValue] = text.stringValue
                }
            }
        
            completion(nil, attachmentArray, activityArray, textHash)
        }
    }
    
    class func muteActivity(_ user:User, tokens:[String], shouldMute:Bool, completion: @escaping ((Error?, Bool) -> Void)){
        let url = "\(self.baseUrl)/v2.0/user/\(user.email)/emails/mute"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        
        let muteString = shouldMute ? "1" : "0"
        let parameters = ["tokens":tokens.joined(separator: ","),
                          "mute": muteString]
        
        self.request(user, url: url, method: .post, parameters: parameters, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false),
                let _ = try! JSON(data: dataFromString).dictionaryValue["message"]?.string else {
                    completion(response.error, false)
                    return
            }
            
            completion(nil, true)
        }
    }
    
    class func getMailSnippets(_ user:User, tokens:[String], completion: @escaping ((Error?, [String:String]?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/emails/snippet"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        let parameters = ["tokens":tokens]
        
        self.request(user, url: url, method: .post, parameters: parameters, headers: headers) { (response) in
            guard let value = response.result.value,
                let dataFromString = value.data(using: .utf8, allowLossyConversion: false),
                let jsonArray = try! JSON(data: dataFromString).dictionaryValue["mails"]?.array else {
                    completion(response.error, nil)
                    return
            }
            
            var textHash = [String:String]()
            
            for jsonObject in jsonArray {
                
                let jsonVar = jsonObject.dictionaryValue
                print(jsonVar)
                
                if let token = jsonVar["token"],
                    let snippet = jsonVar["snippet"] {
                    textHash[token.stringValue] = snippet.stringValue
                }
            }
            
            completion(nil, textHash)
        }
    }

    
    class func getMailText(_ user:User, token:String, completion: @escaping ((Error?, String?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/email/show/\(token)/text"
        
        let headers = ["Authorization": "Basic \(user.auth)"]
        
        self.request(user, url: url, method: .get, parameters: nil, headers: headers) { (response) in
            guard let value = response.result.value else {
                completion(response.error, nil)
                return
            }
            
            completion(nil, value)
        }
    }
    
    class func getDraftId(message id:String, service:GTLRService, completion: @escaping ((Error?, String?) -> Void)){
        let listQuery = GTLRGmailQuery_UsersDraftsList.query(withUserId: "me")
        listQuery.q = "rfc822msgid:\(id)"
        
        service.executeQuery(listQuery) { (listTicket, listResponse, error) in
            if let error = error {
                print(error.localizedDescription)
                completion(error, nil)
                return
            }
            
            guard let messageList = listResponse as? GTLRGmail_ListDraftsResponse,
                let drafts = messageList.drafts,
                let draft = drafts.first,
                let draftId = draft.identifier else {
                    //no draft in relation to this message id
                    completion(nil, nil)
                    return
            }
            
            completion(nil, draftId)
        }
        
    }
}

extension APIManager {
    class func upload(_ file:Data, id:String, fileName:String, mimeType:String, from user:User, delegate:ProgressDelegate?, completion: @escaping ((Error?, String?) -> Void)){
        let url = "\(self.baseUrl)/v2.0/attachment/upload"
        
        let headers = ["Authorization": "Basic \(user.auth)", "fileid": id]
        
        let parameters = ["userid":String(user.id)]
        
        Alamofire.upload(multipartFormData: { (multipartFormData) in
            for (key, value) in parameters {
                multipartFormData.append(value.data(using: String.Encoding.utf8)!, withName: key)
            }
            multipartFormData.append(file, withName: "files", fileName: fileName, mimeType: mimeType)
        }, to: url, method: .post, headers: headers) { (result) in
            switch result {
            case .success(let upload, _, _):
                
                upload.uploadProgress(closure: { (Progress) in
                    print("Upload Progress: \(Progress.fractionCompleted)")
                    if let delegate = delegate {
                        delegate.updateProgress(Progress.fractionCompleted, for: id)
                    }
                })
                
                upload.responseJSON { responseObject in
                    
                    guard responseObject.response?.statusCode == 200,
                        let value = responseObject.result.value else {
                            //check if request was cancelled
                            
                            if responseObject.result.isFailure,
                                let error = responseObject.result.error as NSError?,
                                error.code == CODE_REQUEST_CANCELLED {
                                //do nothing
                                return
                            }
                            
                            var code = -1
                            var userInfo = ["error": ["title":"Network Error", "description":"Please try again later"]]
                            
                            //check if error is due to file size
                            if let response = responseObject.response, response.statusCode == CODE_FILE_SIZE_EXCEEDED {
                                print("===== error file size")
                                print(response.statusCode)
                                code = response.statusCode
                                
                                userInfo["error"]!["title"] = nil
                                
                                userInfo["error"]!["description"] = "File size " + (user.isPro() ? "100 MB" : "5 MB") + " limit exceeded"
                            }
                            
                            completion(NSError(domain: "com.criptext.com", code: code, userInfo: userInfo), nil)
                            return
                    }
                    
                    let jsonVar = JSON(value)
                    
                    let errorCode = jsonVar["error"].intValue
                    
                    guard errorCode == self.CODE_SUCESS else {
                        completion(NSError(domain: "com.criptext.com", code: errorCode, userInfo: nil), nil)
                        return
                    }
                    
                    let token = jsonVar["tokenfile"].stringValue
                    
                    completion(nil, token)
                    
                    print("JSON: \(jsonVar)")
                }
                
            case .failure(let encodingError):
                //self.delegate?.showFailAlert()
                print(encodingError)
                completion(NSError(domain: "com.criptext.com", code: -1, userInfo: ["error": ["title":"Network Error", "description":"Please try again later"]]), nil)
            }
        }
    }
    
    class func sendMail(to recipients:[String],
                        cc: [String],
                        bcc: [String],
                        subject:String,
                        body:String,
                        replyBody:String?,
                        messageId:String?,
                        threadId:String?,
                        draftId:String?,
                        encrypted:Bool,
                        from user:User,
                        with attachments:[Attachment],
                        expiration:(Int, ExpirationType),
                        completion: @escaping ((String?, String?) -> Void)){
        
        if !self.reachabilityManager.isReachable {
            completion("No internet connection", nil)
            return
        }
        
        if user.authentication == nil {
            completion("User authentication failed", nil)
            return
        }
        
        
        let plainAttachments = attachments.filter({$0.isEncrypted == false})
        var arrayPlainObjects = [(URL?,String,String)]()
        for plainAttachment in plainAttachments {
            arrayPlainObjects.append((plainAttachment.fileURL, plainAttachment.fileName, plainAttachment.mimeType))
        }
        
        user.authentication.getTokensWithHandler { (auth, error) in
            
            guard let auth = auth else {
                completion("User token generation failed", nil)
                return
            }
                
            let url = "\(self.baseUrl)/gmail/send"
            let headers = ["Authorization": "Basic \(user.auth)"]
            
            let secureAttachments = attachments.filter({$0.isEncrypted == true})
            
            
            let fileTokens = secureAttachments.map({return $0.fileToken}).joined(separator: ",")
            let fileProps = secureAttachments.map({return $0.isReadOnly ? "1" : "0"}).joined(separator: ",")
            let filePasswords = secureAttachments.map({return $0.currentPassword}).joined(separator: ",")
            let fileSizes = secureAttachments.map({return String($0.size)}).joined(separator: ",")
            let fileNames = secureAttachments.map({return $0.fileName}).joined(separator: ",")
            
            var semail = "\(user.fullName) <\(user.email)>"
            
            if let semailData = semail.data(using: .ascii, allowLossyConversion: true),
                let semailString = String(data: semailData, encoding: .utf8) {
                semail = semailString
            }
            
            var remail = recipients.joined(separator: ",")
            
            if let remailData = remail.data(using: .ascii, allowLossyConversion: true),
                let remailString = String(data: remailData, encoding: .utf8) {
                remail = remailString
            }
            
            var parameters = ["access_token": auth.accessToken,
                              "semail": semail,
                              "remail": remail,
                              "encrypted": encrypted ? "1" : "0",
                              "is_mobile": "true"
                ] as [String:String]
            
            if !bcc.isEmpty {
                if let bccData = bcc.joined(separator: ",").data(using: .ascii, allowLossyConversion: true),
                    let bccString = String(data: bccData, encoding: .utf8) {
                    parameters["bcc"] = bccString
                } else {
                    parameters["bcc"] = bcc.joined(separator: ",")
                }
            }
            
            if !cc.isEmpty {
                if let ccData = cc.joined(separator: ",").data(using: .ascii, allowLossyConversion: true),
                    let ccString = String(data: ccData, encoding: .utf8) {
                    parameters["cc"] = ccString
                } else {
                    parameters["cc"] = cc.joined(separator: ",")
                }
            }
            
            if let messageId = messageId {
                parameters["reply_to"] = messageId
            }
            
            if let threadId = threadId {
                parameters["thread_id"] = threadId
            }
            
            if let draftId = draftId {
                parameters["draft_id"] = draftId
            }
            
            if let replyBody = replyBody {
                parameters["full_body"] = replyBody
            }
            
            if !encrypted{
                if let subjectData = subject.data(using: .ascii, allowLossyConversion: true),
                    let subjectString = String(data: subjectData, encoding: .utf8) {
                    parameters["subject"] = subjectString
                } else {
                    parameters["subject"] = subject
                }
//                parameters["subject"] = subject
                parameters["bodyemail"] = body
                
            } else {
                let aesIvString = MOKSecurityManager.sharedInstance().generateAESKeyAndIV()!
                let aesIv = aesIvString.components(separatedBy: ":")
                
                let encryptedKeys = MOKSecurityManager.sharedInstance().rsaEncryptString(aesIvString, publicKey: user.pubKey)!
                
                let seconds = expiration.0
                let type = expiration.1.rawValue
                
                let params = ["seconds": seconds,
                              "tipo": type,
                              "subject": subject,
                              "lang": "2",
                              "message": body,
                              "from": String(user.id),
                              "forward": "0"] as [String : Any]
                
                let jsonData:Data!
                do {
                    //Convert to Data
                    jsonData = try JSONSerialization.data(withJSONObject: params, options: JSONSerialization.WritingOptions.prettyPrinted)
                } catch {
                    completion("Fail parsing the parameters", nil)
                    return
                }
                let jsonString =  String(data: jsonData, encoding: String.Encoding.utf8)!
                
                let encryptedParams = MOKSecurityManager.sharedInstance().aesEncryptText(jsonString, withKey: aesIv.first!, andIV: aesIv.last!)!
                
                parameters["sid"] = String(user.id)
                parameters["sk"] = encryptedKeys
                parameters["params"] = encryptedParams
            }
            
            if fileTokens.characters.count > 0 {
                parameters["files"] = fileTokens
                parameters["file_props"] = fileProps
                parameters["file_password"] = filePasswords
                parameters["file_names"] = fileNames
                parameters["file_sizes"] = fileSizes
            }
            
            Alamofire.upload(multipartFormData: { (multipartFormData) in
                
                for (key, value) in parameters {
                    
                    multipartFormData.append(value.data(using: String.Encoding.utf8)!, withName: key)
                }
                
                for plainObject in arrayPlainObjects {
                    
                    guard let fileURL = plainObject.0, let data = FileManager.default.contents(atPath: fileURL.path) else {
                        continue
                    }
                    
                    multipartFormData.append(data, withName: "files", fileName: plainObject.1, mimeType: plainObject.2)
                }
            }, to: url, method: .post, headers: headers) { (result) in
                switch result {
                case .success(let upload, _, _):
                    
                    upload.uploadProgress(closure: { (Progress) in
                        print("Upload Progress: \(Progress.fractionCompleted)")
                        //                        if let delegate = delegate {
                        //                            delegate.updateProgress(Progress.fractionCompleted, for: id)
                        //                        }
                    })
                    
                    upload.responseJSON { response in
                        guard response.response?.statusCode == 200,
                            let value = response.result.value else {
                                debugPrint(response)
                                completion("Empty response from the server", nil)
                                return
                        }
                        
                        let jsonVar = JSON(value)
                        
                        let errorCode = jsonVar["error"].intValue
                        
                        guard errorCode == self.CODE_SUCESS else {
                            completion("Server error with code: \(errorCode)", nil)
                            return
                        }
                        
                        completion(nil, jsonVar["message"].stringValue)
                    }
                    
                case .failure(let encodingError):
                    print(encodingError)
                    completion("Encoding error: \(encodingError)", nil)
                }
            }
        }
    }
    
    class func draftMail(to recipients:[(String,String)],
                         cc:[(String,String)],
                         bcc:[(String,String)],
                         subject:String,
                         body:String,
                         threadId:String?,
                         attachments:[AttachmentGmail]?,
                         from user:User,
                         service:GTLRService,
                         completion: @escaping ((Error?, Bool?) -> Void)){
        
        let draft = self.createDraftObject(user.fullName, email: user.email, subject: subject, body: body, threadId: threadId, recipients: recipients, attachments: attachments, cc: cc, bcc: bcc)
        
        let query = GTLRGmailQuery_UsersDraftsCreate.query(withObject: draft, userId: "me", uploadParameters: nil)

        service.executeQuery(query) { (ticket, result, error) in
            if error == nil {
                completion(nil, true)
            }else {
                completion(error, false)
            }
        }
    }
    
    class func updateDraft(message id:String,
                           threadId:String,
                           to recipients:[(String,String)],
                           cc:[(String,String)],
                           bcc:[(String,String)],
                           subject:String,
                           body:String,
                           attachments:[AttachmentGmail]?,
                           from user:User,
                           service:GTLRService,
                           completion: @escaping ((Error?, Bool?) -> Void)){
        
        
        self.getDraftId(message: id, service: service) { (error, draftId) in
            
            guard let draftId = draftId else {
                //no draft in relation to this message id
                completion(error, false)
                return
            }
            
            let draftObject = self.createDraftObject(user.fullName, email: user.email, subject: subject, body: body, threadId: threadId, recipients: recipients, attachments: attachments, cc: cc, bcc: bcc)
            draftObject.identifier = draftId
            
//                        GTLRUploadParameters(fileURL: <#T##URL#>, mimeType: <#T##String#>)
            let query = GTLRGmailQuery_UsersDraftsUpdate.query(withObject: draftObject, userId: "me", identifier: draftId, uploadParameters: nil)
            
            
            service.executeQuery(query) { (ticket, result, error) in
                if error == nil {
                    completion(nil, true)
                }else {
                    completion(error, false)
                }
            }
        }
    }
    
    class func createDraftObject(_ name: String,
                                 email:String,
                                 subject:String,
                                 body:String,
                                 threadId:String?,
                                 recipients:[(String,String)],
                                 attachments:[AttachmentGmail]?,
                                 cc:[(String,String)],
                                 bcc:[(String,String)]) -> GTLRGmail_Draft{
        
        var toString = "To: "
        for (name, email) in recipients {
            toString = toString+"\(name) <\(email)>, "
        }
        
        var ccString = "Cc: "
        for (name, email) in cc {
            ccString = ccString+"\(name) <\(email)>, "
        }
        
        var bccString = "Bcc: "
        for (name, email) in bcc {
            bccString = bccString+"\(name) <\(email)>, "
        }
        
        let message = GTLRGmail_Message(json: [:])
        let draft = GTLRGmail_Draft(json: [:])
        
//        guard let attachments = attachments, !attachments.isEmpty else {
            var messageString = "From: \""+name+"\" <"+email+">\r\n"
            messageString = messageString+toString+"\r\n"
            messageString = messageString+ccString+"\r\n"
            messageString = messageString+bccString+"\r\n"
            messageString = messageString+"Subject: "+subject+"\r\n"
            messageString = messageString+"Content-type: text/html;charset=iso-8859-1\r\n\r\n"
            messageString = messageString+body
            let data:Data = messageString.data(using: String.Encoding.utf8)!
            let base64Encoded = GTLREncodeWebSafeBase64(data)
            message.raw = base64Encoded
            
            if let threadId = threadId {
                message.threadId = threadId
            }
            
            draft.message = message
            return draft
//        }
        
        let bodyPart = GTLRGmail_MessagePart(json: [:])
        var parts = [GTLRGmail_MessagePart]()
        
        //populate headers
        let toHeader = GTLRGmail_MessagePartHeader(json: [:])
        toHeader.name = "To"
        toHeader.value = toString
        
        let fromHeader = GTLRGmail_MessagePartHeader(json: [:])
        fromHeader.name = "From"
        fromHeader.value = "\"\(name)\" <\(email)>"
        
        let ccHeader = GTLRGmail_MessagePartHeader(json: [:])
        ccHeader.name = "Cc"
//        ccHeader.value = cc.joined(separator: ",")
        
        let bccHeader = GTLRGmail_MessagePartHeader(json: [:])
        bccHeader.name = "Bcc"
//        bccHeader.value = bcc.joined(separator: ",")
        
        let subjectHeader = GTLRGmail_MessagePartHeader(json: [:])
        subjectHeader.name = "Subject"
        subjectHeader.value = subject
        
        let contentTypeHeader = GTLRGmail_MessagePartHeader(json: [:])
        contentTypeHeader.name = "Content-Type"
        contentTypeHeader.value = "multipart/mixed"
        
        bodyPart.headers = [toHeader,
                        fromHeader,
                        ccHeader,
                        bccHeader,
                        subjectHeader,
                        contentTypeHeader]
        bodyPart.mimeType = "multipart/mixed"
        
        //set content part
        let contentBodyPart = GTLRGmail_MessagePartBody(json: [:])
        contentBodyPart.data = GTLREncodeWebSafeBase64(body.data(using: String.Encoding.utf8)!)
        
        let contentPart = GTLRGmail_MessagePart(json: [:])
        contentPart.mimeType = "text/html"
        contentPart.body = contentBodyPart
        
        parts.append(contentPart)
//        bodyPart.parts
        
        ///set attachments
        for attachment in attachments! {
            let attachmentPart = GTLRGmail_MessagePart(json: [:])
            attachmentPart.mimeType = attachment.mimeType
            attachmentPart.filename = attachment.fileName
            
            let attachmentContentTypeHeader = GTLRGmail_MessagePartHeader(json: [:])
            attachmentContentTypeHeader.name = "Content-Type"
            attachmentContentTypeHeader.value = "\(attachment.mimeType); name=\"\(attachment.fileName)\""
            
            let attachmentContentDispositionHeader = GTLRGmail_MessagePartHeader(json: [:])
            attachmentContentDispositionHeader.name = "Content-Disposition"
            attachmentContentDispositionHeader.value = "attachment; filename=\"\(attachment.fileName)\""
            
            attachmentPart.headers = [attachmentContentTypeHeader, attachmentContentDispositionHeader]
            
            let attachmentContentBodyPart = GTLRGmail_MessagePartBody(json: [:])
            attachmentContentBodyPart.attachmentId = attachment.attachmentId
            attachmentContentBodyPart.size = NSNumber(integerLiteral: attachment.size)
            
            parts.append(attachmentPart)
        }
        
        bodyPart.parts = parts
        
        message.payload = bodyPart
        
        
        if let threadId = threadId {
            message.threadId = threadId
        }
        
        draft.message = message
        
        return draft
    }
}

extension APIManager {
    
    class func info(_ labels:[String],
                      with service:GTLRService,
                      user id:String,
                      completionHandler handler:@escaping ((Error?, [GTLRGmail_Label]?) -> ())){
        var queryArray:[GTLRQuery] = []
        
        for label in labels {
            let query = GTLRGmailQuery_UsersLabelsGet.query(withUserId: id, identifier: label)
            queryArray.append(query)
        }
        
        service.executeQuery(GTLRBatchQuery(queries: queryArray)) { (ticket, result, error) in
            
            if let error = error {
                print(error.localizedDescription)
                handler(error, nil)
                return
            }
            
            guard let trueResult = (result as! GTLRBatchResult).successes else {
                handler(error, nil)
                return
            }
            
            var labelArray = [GTLRGmail_Label]()
            for (_, object) in trueResult {
                guard let label = object as? GTLRGmail_Label else {
                    continue
                }
                labelArray.append(label)
            }
            
            handler(nil, labelArray)
        }
    }
    
    class func watch(labels: [String],
                     topic:String,
                     with service:GTLRService,
                     user id:String,
                     completionHandler handler:@escaping ((Error?, Bool) -> ())) {
        let request = GTLRGmail_WatchRequest(json: ["labelIds":labels, "topicName":topic])
        
        let query = GTLRGmailQuery_UsersWatch.query(withObject: request, userId: id)
        
        service.executeQuery(query) { (ticket, response, error) in
            if error == nil {
                handler(nil, true)
            }else{
                handler(error, false)
            }
        }
    }
    
    class func stopNotifications(user id:String,
                                 with service:GTLRService,
                                 completionHandler handler:@escaping ((Error?, Bool) -> ())) {
        let query = GTLRGmailQuery_UsersStop.query(withUserId: id)
        
        service.executeQuery(query) { (ticket, response, error) in
            if error == nil {
                handler(nil, true)
            }else{
                handler(error, false)
            }
        }
    }
    
    class func generateModifyObject(add newLabels:[String]?, remove oldLabels:[String]?) -> [String:[String]]{
        var modifyDict:[String:[String]] = [:]
        
        if let newLabels = newLabels {
            modifyDict["addLabelIds"] = newLabels
        }
        
        if let oldLabels = oldLabels {
            modifyDict["removeLabelIds"] = oldLabels
        }
        
        return modifyDict
    }
    
    class func threadModifyLabels(add newLabels:[String]?,
                                  remove oldLabels:[String]?,
                                  from emails:[String],
                                  with service:GTLRService,
                                  user id:String,
                                  completionHandler handler:@escaping ((Error?, Bool) -> ())) {
        
        let modifyDict = self.generateModifyObject(add: newLabels, remove: oldLabels)
        
        guard !modifyDict.isEmpty else{
            handler(NSError(domain: "com.criptext.com", code: -1, userInfo: nil), false)
            return
        }
        
        var queryArray:[GTLRQuery] = []
        for identifier in emails {
            let threadRequest = GTLRGmail_ModifyThreadRequest(json: modifyDict)
            let query = GTLRGmailQuery_UsersThreadsModify.query(withObject: threadRequest, userId: id, identifier: identifier)
            queryArray.append(query)
        }
        
        service.executeQuery(GTLRBatchQuery(queries: queryArray)) { (ticket, result, error) in
            if error == nil {
                handler(nil, true)
            }else{
                handler(error, false)
            }
        }
    }
    
    class func messageModifyLabels(add newLabels:[String]?, remove oldLabels:[String]?, from emails:[String], with service:GTLRService, user id:String, completionHandler handler:@escaping ((Error?, Bool) -> ())) {
        
        let modifyDict = self.generateModifyObject(add: newLabels, remove: oldLabels)
        
        guard !modifyDict.isEmpty else{
            handler(NSError(domain: "com.criptext.com", code: -1, userInfo: nil), false)
            return
        }
        
        var queryArray:[GTLRQuery] = []
        for identifier in emails {
            let messageRequest = GTLRGmail_ModifyMessageRequest(json: modifyDict)
            let query = GTLRGmailQuery_UsersMessagesModify.query(withObject: messageRequest, userId: id, identifier: identifier)
            queryArray.append(query)
        }
        
        service.executeQuery(GTLRBatchQuery(queries: queryArray)) { (ticket, result, error) in
            if error == nil {
                handler(nil, true)
            }else{
                handler(error, false)
            }
        }
    }
    
    class func trash(emails ids:[String], with service:GTLRService, completionHandler handler:@escaping ((Error?, Bool) -> ())) {
        var queryArray:[GTLRQuery] = []
        for id in ids {
            let query = GTLRGmailQuery_UsersThreadsTrash.query(withUserId: "me", identifier: id)
            queryArray.append(query)
        }
        
        service.executeQuery(GTLRBatchQuery(queries: queryArray)) { (ticket, result, error) in
            if error == nil {
                handler(nil, true)
            }else{
                handler(error, false)
            }
        }
    }
    
    class func delete(emails ids:[String], with service:GTLRService, completionHandler handler:@escaping ((Error?, Bool) -> ())) {
        var queryArray:[GTLRQuery] = []
        for id in ids {
            let query = GTLRGmailQuery_UsersThreadsDelete.query(withUserId: "me", identifier: id)
            queryArray.append(query)
        }
        
        service.executeQuery(GTLRBatchQuery(queries: queryArray)) { (ticket, result, error) in
            if error == nil {
                handler(nil, true)
            }else{
                handler(error, false)
            }
        }
    }
    
    class func download(attachment identifier:String, for messageId:String, with service:GTLRService, user id:String, completionHandler handler:@escaping ((Error?, Data?) -> ())) {
        
        let query = GTLRGmailQuery_UsersMessagesAttachmentsGet.query(withUserId: id, messageId: messageId, identifier: identifier)
        
        service.executeQuery(query) { (ticket, result, error) in
            guard var attachmentBase64 = (result as? GTLRGmail_MessagePartBody)?.data else {
                handler(error, nil)
                return
            }
            
            attachmentBase64 = attachmentBase64.replacingOccurrences(of: "-", with: "+")
            attachmentBase64 = attachmentBase64.replacingOccurrences(of: "_", with: "/")
            
            handler(nil, Data(base64Encoded: attachmentBase64))
        }
    }
    
    class func download(from url:URL, to:URL, delegate:ProgressDelegate?, completion: @escaping ((Error?, URL?) -> Void)){
        
        let destination: DownloadRequest.DownloadFileDestination = { _, _ in
            return (to, [.removePreviousFile, .createIntermediateDirectories])
        }
        let donwloadUrl = "https://mail.criptext.com\(url.path)"
        Alamofire.download(donwloadUrl, to: destination).downloadProgress { progress in
            print("Download Progress: \(progress.fractionCompleted)")
            if let delegate = delegate {
                delegate.updateProgress(progress.fractionCompleted, for: url.path)
            }
            }
            .responseData { response in
                if response.error == nil, let url = response.destinationURL {
                    completion(nil, url)
                    return
                }
                
                completion(response.error, nil)
        }
    }
    
    //error, ticket, emailsAdded[Email], emailsDeleted[String], labelsAdded[String:[String]], labelsRemoved[String:[String]]
    class func getUpdates(_ service:GTLRService, since historyId:Int64, folder label:Label, user id:String, completionHandler handler: @escaping ((GTLRServiceTicket, [Email]?, [String]?, [String:[String]]?, [String:[String]]?, [Contact]?, Error?) -> Void)){
        
        let query = GTLRGmailQuery_UsersHistoryList.query(withUserId: id)
        query.startHistoryId = UInt64(historyId)
        query.labelId = label.id
        
        service.executeQuery(query) { (ticket, listResponse, error) in
            if let error = error {
                print(error.localizedDescription)
                handler(ticket, nil, nil, nil, nil, nil, error)
                return
            }
            
            guard let messageList = listResponse as? GTLRGmail_ListHistoryResponse, let messages = messageList.history else {
                handler(ticket, [], [], [:], [:], [], nil)
                //no emails in this box
                return
            }
            
            var queryArray:[GTLRQuery] = []
            var emailsDeleted = [String]()
            var labelsAdded = [String:[String]]()
            var labelsRemoved = [String:[String]]()
            
            for message in messages {
                if let messagesAdded = message.messagesAdded{
                    print("======== messages added")
                    for messageAdded in messagesAdded {
                        if let realMessage = messageAdded.message {
                            let maquery = GTLRGmailQuery_UsersThreadsGet.query(withUserId: "me", identifier: realMessage.threadId!)
                            queryArray.append(maquery)
                        }
                    }
                }
                
                if let listLabelsAdded = message.labelsAdded {
                    print("======== labels added")
                    for labelAdded in listLabelsAdded {
                        if let realMessage = labelAdded.message {
                            labelsAdded[realMessage.identifier!] = labelAdded.labelIds ?? []
                        }
                    }
                }
                
                if let listLabelsRemoved = message.labelsRemoved {
                    print("======== labels removed")
                    for labelRemoved in listLabelsRemoved {
                        if let realMessage = labelRemoved.message {
                            labelsRemoved[realMessage.identifier!] = labelRemoved.labelIds ?? []
                        }
                    }
                }
                
                if let messagesDeleted = message.messagesDeleted {
                    print("======== messages deleted")
                    for messageDeleted in messagesDeleted {
                        if let realMessage = messageDeleted.message {
                            emailsDeleted.append(realMessage.identifier!)
                        }
                    }
                }
            }
            
            if queryArray.count == 0 {
                return handler(ticket, [], emailsDeleted, labelsAdded, labelsRemoved, nil, nil)
            }
            
            //get list of email ids
            service.executeQuery(GTLRBatchQuery(queries: queryArray), completionHandler: { (emailTicket, batchResult, errorBatch) in
                if let errorBatch = errorBatch {
                    print(errorBatch.localizedDescription)
                    handler(emailTicket, [], emailsDeleted, labelsAdded, labelsRemoved, nil, errorBatch)
                    return
                }
                
                guard let trueResult = (batchResult as! GTLRBatchResult).successes else {
                    handler(ticket, [], emailsDeleted, labelsAdded, labelsRemoved, nil, errorBatch)
                    return
                }
                
                let parsedObject = self.parseEmails(trueResult, ticket: ticket)
                let emailArray = parsedObject.0
                
                handler(ticket, emailArray, emailsDeleted, labelsAdded, labelsRemoved, parsedObject.1, nil)
            })
        }
    }
    
    class func getMails(_ service:GTLRService, userId:String, labels:[String], pageToken:String?, completionHandler handler: @escaping ((GTLRServiceTicket, [Email]?, [Contact]?, Error?) -> Void)){
        
        let query = GTLRGmailQuery_UsersThreadsList.query(withUserId: userId)
        query.includeSpamTrash = false
        query.maxResults = 50
        
        //catch `All mails` selected
        if !labels.isEmpty && labels != [""]{
            query.labelIds = labels
        }
        
        if let pageToken = pageToken {
            query.pageToken = pageToken
        }

        service.executeQuery(query) { (ticket, listResponse, error) in
            if let error = error {
                print(error.localizedDescription)
                handler(ticket, nil, nil, error)
                return
            }
            
            guard let messageList = listResponse as? GTLRGmail_ListThreadsResponse, let messages = messageList.threads else {
                handler(ticket, [], [], nil)
                //no emails in this box
                return
            }
            
            var queryArray:[GTLRQuery] = []
            for message in messages {
                let maquery = GTLRGmailQuery_UsersThreadsGet.query(withUserId: "me", identifier: message.identifier!)
                queryArray.append(maquery)
            }
            
            //get list of email ids
            service.executeQuery(GTLRBatchQuery(queries: queryArray), completionHandler: { (emailTicket, batchResult, errorBatch) in
                if let errorBatch = errorBatch {
                    print(errorBatch.localizedDescription)
                    handler(emailTicket, nil, nil, errorBatch)
                    return
                }
                
                guard let trueResult = (batchResult as! GTLRBatchResult).successes else {
                    handler(ticket, [], [], errorBatch)
                    return
                }
                
                let parsedObjects = self.parseEmails(trueResult, ticket: ticket)
                
                var parsedEmails = parsedObjects.0
                
                parsedEmails.sort(by: { $0.date?.compare($1.date!) == ComparisonResult.orderedAscending })
                
                let parsedContacts = parsedObjects.1
                
                handler(ticket, parsedEmails, parsedContacts, nil)
            })
        }
    }
    
    class func searchMails(_ service:GTLRService, userId:String, searchText:String?, pageToken:String?, completionHandler handler: @escaping ((GTLRServiceTicket, [Email]?, Error?) -> Void)) -> GTLRServiceTicket {
        
        let query = GTLRGmailQuery_UsersThreadsList.query(withUserId: userId)
        if let searchText = searchText {
            query.q = searchText
        }
        if let pageToken = pageToken {
            if(pageToken != "0"){
                query.pageToken = pageToken
            }
        }
        
        return service.executeQuery(query) { (ticket, listResponse, error) in
            if let error = error {
                print(error.localizedDescription)
                handler(ticket, nil, error)
                return
            }
            
            guard let messageList = listResponse as? GTLRGmail_ListThreadsResponse, let messages = messageList.threads else {
                handler(ticket, [], nil)
                //no emails in this box
                return
            }
            
            var queryArray:[GTLRQuery] = []
            for message in messages {
                let maquery = GTLRGmailQuery_UsersThreadsGet.query(withUserId: "me", identifier: message.identifier!)
                queryArray.append(maquery)
            }
            
            //get list of email ids
            service.executeQuery(GTLRBatchQuery(queries: queryArray), completionHandler: { (emailTicket, batchResult, errorBatch) in
                if let errorBatch = errorBatch {
                    print(errorBatch.localizedDescription)
                    handler(emailTicket, nil, errorBatch)
                    return
                }
                
                guard let trueResult = (batchResult as! GTLRBatchResult).successes else {
                    handler(ticket, [], errorBatch)
                    return
                }
                
                let parsedTuple = self.parseEmails(trueResult, ticket: ticket)
                
                var parsedEmails = parsedTuple.0
                
                parsedEmails.sort(by: { $0.date?.compare($1.date!) == ComparisonResult.orderedDescending })
                
                handler(ticket, parsedEmails, nil)
            })
        }
    }
    
    class func parseEmails(_ batchResponse:[String:GTLRObject], ticket:GTLRServiceTicket) -> ([Email], [Contact]){
        
        var emailArray = [Email]()
        
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy"
        formatter.timeZone = TimeZone.ReferenceType.local
        
        
        //TODO: do something about nextpagetoken
        let nextPageToken = (ticket.fetchedObject as? GTLRGmail_ListThreadsResponse)?.nextPageToken
        
        var contacts = [Contact]()
        
        for emailObject in batchResponse {
            let json = emailObject.value.json as NSDictionary? as? [AnyHashable: Any] ?? [:]
            
            let jsonArray = json["messages"] as! NSArray
            for jsonObject in jsonArray {
                
                let jsonEmail = jsonObject as? NSDictionary as? [AnyHashable: Any] ?? [:]
                
                let email = Email()
                email.id = jsonEmail["id"] as! String
                email.threadId = jsonEmail["threadId"] as! String
                email.historyId = Int64(jsonEmail["historyId"] as! String) ?? 0
                email.nextPageToken = nextPageToken ?? "0"
                email.labels = jsonEmail["labelIds"] as? [String] ?? []
                email.labelArraySerialized = email.labels.joined(separator: ",")
                email.snippet = String(htmlEncodedString: jsonEmail["snippet"] as! String)
                
                email.date = Date(timeIntervalSince1970: TimeInterval(jsonEmail["internalDate"] as! String)! / 1000)
                email.dateString = formatter.string(from: email.date!)
                
                let payload = jsonEmail["payload"] as? NSDictionary? as? [AnyHashable: Any] ?? [:]
                
                let headers = payload["headers"] as! NSArray as? [[AnyHashable: Any]] ?? []
                
                for header in headers {
                    let name = (header["name"] as! String).lowercased()
                    var value = header["value"] as! String
                    
                    switch name {
                    case "from":
                        let contact = Contact()
                        
                        var fromEmail = ""
                        if let match = value.range(of: "(?<=<)[^>]+", options: .regularExpression){
                            fromEmail = value.substring(with: match)
                        }else if (self.isValidEmail(text: value)){
                            fromEmail = value
                        }
                        email.from = fromEmail
                        contact.email = fromEmail
                        
                        if let match = value.range(of: " <[^ ]+", options: .regularExpression){
                            value.removeSubrange(match)
                        }
                        
                        email.fromDisplayString = value
                        contact.displayName = value
                        
                        if !contact.email.isEmpty && contact.email != " " {
                            contact.email = contact.email.replacingOccurrences(of: " ", with: "")
                            contacts.append(contact)
                        }
                        
                        break
                    case "to":
                        var toEmail = ""
                        var toDisplayEmail = ""
                        
                        for tag in value.components(separatedBy: ",") {
                            let contact = Contact()
                            var copyTag = tag
                            let cleantag = tag.replacingOccurrences(of: " ", with: "")
                            
                            if let match = cleantag.range(of: "(?<=<)[^>]+", options: .regularExpression){
                                let email = cleantag.substring(with: match)
                                if(toEmail == "") {
                                    toEmail = email
                                }else{
                                    toEmail = toEmail + "," + email
                                }
                                contact.email = email
                            }else if (self.isValidEmail(text: cleantag)){
                                if(toEmail == "") {
                                    toEmail = tag
                                }else{
                                    toEmail = toEmail + "," + cleantag
                                }
                                
                                contact.email = cleantag
                            }
                            
                            if let match = copyTag.range(of: " <[^ ]+", options: .regularExpression){
                                
                                copyTag.removeSubrange(match)
                                
                                if(toDisplayEmail == "") {
                                    toDisplayEmail = copyTag
                                }else{
                                    toDisplayEmail = toDisplayEmail + "," + copyTag
                                }
                                
                                contact.displayName = copyTag
                            }else {
                                if(toDisplayEmail == "") {
                                    toDisplayEmail = copyTag
                                }else{
                                    toDisplayEmail = toDisplayEmail + "," + copyTag
                                }
                                
                                contact.displayName = copyTag
                            }
                            
                            if !contact.email.isEmpty && contact.email != " " {
                                contact.email = contact.email.replacingOccurrences(of: " ", with: "")
                                contacts.append(contact)
                            }
                        }
                        email.toDisplayString = toDisplayEmail
                        email.to = toEmail
                        break
                    case "cc":
                        var ccEmail = ""
                        var ccDisplayEmail = ""
                        
                        for tag in value.components(separatedBy: ",") {
                            let contact = Contact()
                            let cleantag = tag.replacingOccurrences(of: " ", with: "")
                            var copyTag = tag
                            
                            if let match = cleantag.range(of: "(?<=<)[^>]+", options: .regularExpression){
                                let email = cleantag.substring(with: match)
                                if(ccEmail == "") {
                                    ccEmail = email
                                }else{
                                    ccEmail = ccEmail + "," + email
                                }
                                contact.email = email
                            }else if (self.isValidEmail(text: cleantag)){
                                if(ccEmail == "") {
                                    ccEmail = cleantag
                                }else{
                                    ccEmail = ccEmail + "," + cleantag
                                }
                                contact.email = tag
                            }
                            
                            if let match = copyTag.range(of: " <[^ ]+", options: .regularExpression){
                                
                                copyTag.removeSubrange(match)
                                
                                if(ccDisplayEmail == "") {
                                    ccDisplayEmail = copyTag
                                }else{
                                    ccDisplayEmail = ccDisplayEmail + "," + copyTag
                                }
                                
                                contact.displayName = copyTag
                            }else {
                                if(ccDisplayEmail == "") {
                                    ccDisplayEmail = copyTag
                                }else{
                                    ccDisplayEmail = ccDisplayEmail + "," + copyTag
                                }
                                
                                contact.displayName = copyTag
                            }
                            
                            if !contact.email.isEmpty && contact.email != " " {
                                contact.email = contact.email.replacingOccurrences(of: " ", with: "")
                                contacts.append(contact)
                            }
                        }
                        email.ccDisplayString = ccDisplayEmail
                        email.cc = ccEmail
                        break
                    case "subject":
                        if let subjectData = value.data(using: .utf8, allowLossyConversion: true),
                            let subjectString = String(data: subjectData, encoding: .utf8) {
                            email.subject = subjectString
                        } else {
                            email.subject = value
                        }
                        
                        break
                    case "thread-topic":
                        email.threadSubject = value
                    case "message-id":
                        email.messageId = value
                    default:
                        break
                    }
                }
                
                guard let parts = payload["parts"] as? NSArray as? [[AnyHashable: Any]] else {
                    let bodyObject = payload["body"] as? NSDictionary? as? [AnyHashable: Any] ?? [:]
                    if let body = bodyObject["data"] as? String{
                        
                        email.body = body
                        email.body = email.body.replacingOccurrences(of: "-", with: "+")
                        email.body = email.body.replacingOccurrences(of: "_", with: "/")
                        email.body = String(data: Data(base64Encoded: email.body)!, encoding: .utf8)!
                    }
                    
                    emailArray.append(email)
                    continue
                }
                
                let parsedParts = self.parseParts(parts)
                
                email.body = parsedParts.0
                
                email.body = email.body.replacingOccurrences(of: "-", with: "+")
                email.body = email.body.replacingOccurrences(of: "_", with: "/")
                
                email.body = String(data: Data(base64Encoded: email.body)!, encoding: .utf8)!
                
                if let regex = try? NSRegularExpression(pattern: "\"https:\\/\\/mail\\.criptext\\.com\\/(rs|cache)\\/(\\S+)\"", options: []){
                    let results = regex.matches(in: email.body, options: [], range: NSMakeRange(0, email.body.characters.count))
                    
                    let bodyCopy = NSString(string: email.body)
                    for result in results {
                        let match = result.range
                        
                        var imgUrl = bodyCopy.substring(with: match)
                        imgUrl = imgUrl.replacingOccurrences(of: "https://mail.criptext.com/rs/", with: "")
                        imgUrl = imgUrl.replacingOccurrences(of: "https://mail.criptext.com/cache/", with: "")
                        imgUrl = imgUrl.replacingOccurrences(of: "\"", with: "")
                        
                        email.criptextTokens.append(imgUrl)
                    }
                    
                    email.criptextTokensSerialized = email.criptextTokens.joined(separator: ",")
                    //provisionally, later it has to be adjusted with the thread
                    email.realCriptextToken = email.criptextTokens.first ?? ""
                }
                
                let list = List<AttachmentGmail>()
                list.append(objectsIn: parsedParts.1)
                email.attachments = list
                
                emailArray.append(email)
            }
        }
        
        return (emailArray, contacts)
    }
    
    class func parseParts(_ parts:[[AnyHashable: Any]]) -> (String, [AttachmentGmail]){
        
        var attachmentArray = [AttachmentGmail]()
        var body = ""
        
        for part in parts {
            let mimeType = part["mimeType"] as! String
            let filename = part["filename"] as! String
            
            if mimeType.contains("multipart/") {
                //real body is inside here
                let insideParts = part["parts"] as! NSArray as? [[AnyHashable: Any]] ?? []
                let parsedParts = self.parseParts(insideParts)
                
                body = parsedParts.0
                attachmentArray.append(contentsOf: parsedParts.1)
                continue
            }
            
            //disregard text/plain
            guard mimeType != "text/plain" else {
                continue
            }
            
            let bodyObject = part["body"] as? NSDictionary? as? [AnyHashable: Any] ?? [:]
            
            if mimeType == "text/html" && filename == "" {
                body = bodyObject["data"] as! String
                continue
            }
            
            let headers = part["headers"] as? NSArray as? [[AnyHashable: Any]] ?? []
            
            let attachment = AttachmentGmail()
            
            for header in headers {
                if (header["name"] as! String).lowercased() == "content-id" {
                    attachment.contentId = (header["value"] as! String)
                        .replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
                    break
                }
            }
            
            attachment.fileName = filename
            attachment.mimeType = mimeTypeForPath(path: filename)
            attachment.attachmentId = bodyObject["attachmentId"] as? String ?? ""
            attachment.size = bodyObject["size"] as? Int ?? 0
            attachmentArray.append(attachment)
        }
        
        return (body, attachmentArray)
    }
}

extension APIManager {
    class func isValidEmail(text:String) -> Bool {
        let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        
        let emailTest = NSPredicate(format:"SELF MATCHES %@", emailRegEx)
        return emailTest.evaluate(with: text)
    }
    
    class func cancelUpload(_ id:String) {
        Alamofire.SessionManager.default.session.getTasksWithCompletionHandler { (_, uploadDataArray, _) in
            for upload in uploadDataArray {
                guard let request = upload.originalRequest else {
                    continue
                }
                
                if let fileId = request.value(forHTTPHeaderField: "fileid"), fileId == id {
                    upload.cancel()
                    break
                }
            }
        }
    }
    
    class func cancelAllRequests(){
        Alamofire.SessionManager.default.session.getTasksWithCompletionHandler { (sessionDataArray, uploadDataArray, downloadDataArray) in
            sessionDataArray.forEach { $0.cancel() }
            uploadDataArray.forEach { $0.cancel() }
            downloadDataArray.forEach { $0.cancel() }
        }
    }
    
    class func cancelAllUploads(){
        Alamofire.SessionManager.default.session.getTasksWithCompletionHandler { (_, uploadDataArray, _) in
            uploadDataArray.forEach { $0.cancel() }
        }
    }
}
