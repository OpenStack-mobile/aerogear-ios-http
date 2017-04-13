/*
 * JBoss, Home of Professional Open Source.
 * Copyright Red Hat, Inc., and individual contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

/**
 The HTTP method verb:
 
 - GET:    GET http verb
 - HEAD:   HEAD http verb
 - DELETE:  DELETE http verb
 - POST:   POST http verb
 - PUT:    PUT http verb
 */
public enum HttpMethod: String {
    case get = "GET"
    case head = "HEAD"
    case delete = "DELETE"
    case post = "POST"
    case put = "PUT"
}

/**
 The file request type:
 
 - Download: Download request
 - Upload:   Upload request
 */
enum FileRequestType {
    case download(String?)
    case upload(UploadType)
}

/**
 The Upload enum type:
 
 - Data:   for a generic NSData object
 - File:   for File passing the URL of the local file to upload
 - Stream:  for a Stream request passing the actual NSInputStream
 */
enum UploadType {
    case data(Foundation.Data)
    case file(URL)
    case stream(InputStream)
}

/**
Error domain.
**/
public let HttpErrorDomain = "HttpDomain"
/**
Request error.
**/
public let NetworkingOperationFailingURLRequestErrorKey = "NetworkingOperationFailingURLRequestErrorKey"
/**
 Response error.
 **/
public let NetworkingOperationFailingURLResponseErrorKey = "NetworkingOperationFailingURLResponseErrorKey"

public typealias ProgressBlock = (Int64, Int64, Int64) -> Void
public typealias CompletionBlock = (Any?, NSError?) -> Void

/**
 Main class for performing HTTP operations across RESTful resources.
 */
public class Http {
    
    var baseURL: String?
    var session: URLSession
    var requestSerializer: RequestSerializer
    var responseSerializer: ResponseSerializer
    open var authzModule:  AuthzModule?
    
    fileprivate var delegate: SessionDelegate
    
    /**
     Initialize an HTTP object.
     
     :param: baseURL the remote base URL of the application (optional).
     :param: sessionConfig the SessionConfiguration object (by default it uses a defaultSessionConfiguration).
     :param: requestSerializer the actual request serializer to use when performing requests.
     :param: responseSerializer the actual response serializer to use upon receiving a response.
     
     :returns: the newly intitialized HTTP object
     */
    public init(baseURL: String? = nil,
                sessionConfig: URLSessionConfiguration = URLSessionConfiguration.default,
                requestSerializer: RequestSerializer = JsonRequestSerializer(),
                responseSerializer: ResponseSerializer = JsonResponseSerializer()) {
        self.baseURL = baseURL
        self.delegate = SessionDelegate()
        self.session = URLSession(configuration: sessionConfig, delegate: self.delegate, delegateQueue: OperationQueue.main)
        self.requestSerializer = requestSerializer
        self.responseSerializer = responseSerializer
    }
    
    deinit {
        self.session.finishTasksAndInvalidate()
    }
    
    /**
     Gateway to perform different http requests including multipart.
     
     :param: url the url of the resource.
     :param: parameters the request parameters.
     :param: method the method to be used.
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    private func request(url: String, parameters: [String: AnyObject]? = nil,  method: HttpMethod,  credential: NSURLCredential? = nil, retry: Bool, completionHandler: CompletionBlock) {
        let block: () -> Void =  {
            let finalOptURL = self.calculateURL(baseURL: self.baseURL, url: path)
            guard let finalURL = finalOptURL else {
                let error = NSError(domain: "AeroGearHttp", code: 0, userInfo: [NSLocalizedDescriptionKey: "Malformed URL"])
                completionHandler(nil, error)
                return
            }
            
            var request: URLRequest
            var task: URLSessionTask?
            var delegate: TaskDataDelegate
            // Merge headers
            let headers = merge(self.requestSerializer.headers, self.authzModule?.authorizationFields())
            
            // care for multipart request is multipart data are set
            if (self.hasMultiPartData(httpParams: parameters)) {
                request = self.requestSerializer.multipartRequest(url: finalURL, method: method, parameters: parameters, headers: headers)
                task = self.session.uploadTask(withStreamedRequest: request)
                delegate = TaskUploadDelegate()
            } else {
                request = self.requestSerializer.request(url: finalURL, method: method, parameters: parameters, headers: headers)
                task = self.session.dataTask(with: request);
                delegate = TaskDataDelegate()
            }
            
            let innerCompletitionHandler: CompletionBlock = { (response, error) in
                if let authModule = self.authzModule {
                    if (error != nil && (error?.code == 400 || error?.code == 401 || error?.code == 403)  && retry) {
                        authModule.revokeLocalAccessToken()
                        self.request(url, parameters: parameters, method: method, credential: credential, retry: false, completionHandler: completionHandler)
                        return
                    }
                }
                
                completionHandler(response, error)
            }
            
            delegate.completionHandler = innerCompletitionHandler
            delegate.responseSerializer = self.responseSerializer
            delegate.credential = credential
            
            self.delegate[task] = delegate
            if let task = task {task.resume()}
        }
        
        // cater for authz and pre-authorize prior to performing request
        if (self.authzModule != nil) {
            self.authzModule?.requestAccess(completionHandler: { (response, error ) in
                // if there was an error during authz, no need to continue
                if (error != nil) {
                    completionHandler(nil, error)
                    return
                }
                
                // ..otherwise proceed normally
                block();
            })
        } else {
            block()
        }
    }
    
    /**
     Gateway to perform different file requests either download or upload.
     
     :param: url the url of the resource.
     :param: parameters the request parameters.
     :param: method the method to be used.
     :param: type the file request type
     :param: progress  a block that will be invoked to report progress during either download or upload.
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    private func fileRequest(url: String, parameters: [String: AnyObject]? = nil,  method: HttpMethod, credential: NSURLCredential? = nil, type: FileRequestType, progress: ProgressBlock?, completionHandler: CompletionBlock) {
        
        let block: () -> Void  = {
            let finalOptURL = self.calculateURL(baseURL: self.baseURL, url: url)
            guard let finalURL = finalOptURL else {
                let error = NSError(domain: "AeroGearHttp", code: 0, userInfo: [NSLocalizedDescriptionKey: "Malformed URL"])
                completionHandler(nil, error)
                return
            }
            var request: URLRequest
            // Merge headers
            let headers = merge(self.requestSerializer.headers, self.authzModule?.authorizationFields())
            
            // care for multipart request is multipart data are set
            if (self.hasMultiPartData(httpParams: parameters)) {
                request = self.requestSerializer.multipartRequest(url: finalURL, method: method, parameters: parameters, headers: headers)
            } else {
                request = self.requestSerializer.request(url: finalURL, method: method, parameters: parameters, headers: headers)
            }
            
            var task: URLSessionTask?
            
            switch type {
            case .download(let destinationDirectory):
                task = self.session.downloadTask(with: request)
                
                let delegate = TaskDownloadDelegate()
                delegate.downloadProgress = progress
                delegate.destinationDirectory = destinationDirectory as NSString?;
                delegate.completionHandler = completionHandler
                delegate.credential = credential
                delegate.responseSerializer = responseSerializer == nil ? self.responseSerializer : responseSerializer
                self.delegate[task] = delegate
                
            case .upload(let uploadType):
                switch uploadType {
                case .data(let data):
                    task = self.session.uploadTask(with: request, from: data)
                case .file(let url):
                    task = self.session.uploadTask(with: request, fromFile: url)
                case .stream(_):
                    task = self.session.uploadTask(withStreamedRequest: request)
                }
                
                let delegate = TaskUploadDelegate()
                delegate.uploadProgress = progress
                delegate.completionHandler = completionHandler
                delegate.credential = credential
                delegate.responseSerializer = responseSerializer
                
                self.delegate[task] = delegate
            }
            
            if let task = task {task.resume()}
        }
        
        // cater for authz and pre-authorize prior to performing request
        if (self.authzModule != nil) {
            self.authzModule?.requestAccess(completionHandler: { (response, error ) in
                // if there was an error during authz, no need to continue
                if (error != nil) {
                    completionHandler(nil, error)
                    return
                }
                // ..otherwise proceed normally
                block();
            })
        } else {
            block()
        }
    }
    
    /**
     performs an HTTP GET request.
     
     :param: url         the url of the resource.
     :param: parameters  the request parameters.
     :param: credential  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    public func GET(url: String, parameters: [String: AnyObject]? = nil, credential: NSURLCredential? = nil, completionHandler: CompletionBlock) {
        request(url, parameters: parameters,  method:.GET,  credential: credential, retry: true, completionHandler: completionHandler)
    }
    
    /**
     performs an HTTP POST request.
     
     :param: url          the url of the resource.
     :param: parameters   the request parameters.
     :param: credential   the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    public func POST(url: String, parameters: [String: AnyObject]? = nil, credential: NSURLCredential? = nil, completionHandler: CompletionBlock) {
        request(url, parameters: parameters, method:.POST, credential: credential, retry: true, completionHandler: completionHandler)
    }
    
    /**
     performs an HTTP PUT request.
     
     :param: url          the url of the resource.
     :param: parameters   the request parameters.
     :param: credential   the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    public func PUT(url: String, parameters: [String: AnyObject]? = nil, credential: NSURLCredential? = nil, completionHandler: CompletionBlock) {
        request(url, parameters: parameters, method:.PUT, credential: credential, retry: true, completionHandler: completionHandler)
    }
    
    /**
     performs an HTTP DELETE request.
     
     :param: url         the url of the resource.
     :param: parameters  the request parameters.
     :param: credential  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    public func DELETE(url: String, parameters: [String: AnyObject]? = nil, credential: NSURLCredential? = nil, completionHandler: CompletionBlock) {
        request(url, parameters: parameters, method:.DELETE, credential: credential, retry: true, completionHandler: completionHandler)
    }
    
    /**
     performs an HTTP HEAD request.
     
     :param: url         the url of the resource.
     :param: parameters  the request parameters.
     :param: credential  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    public func HEAD(url: String, parameters: [String: AnyObject]? = nil, credential: NSURLCredential? = nil, completionHandler: CompletionBlock) {
        request(url, parameters: parameters, method:.HEAD, credential: credential, retry: true, completionHandler: completionHandler)
    }
    
    /**
     Request to download a file.
     
     :param: url                     the URL of the downloadable resource.
     :param: destinationDirectory    the destination directory where the file would be stored, if not specified. application's default '.Documents' directory would be used.
     :param: parameters              the request parameters.
     :param: credential              the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: method                  the method to be used, by default a .GET request.
     :param: progress                a block that will be invoked to report progress during download.
     :param: completionHandler       a block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    public func download(url: String,  destinationDirectory: String? = nil, parameters: [String: AnyObject]? = nil, credential: NSURLCredential? = nil, method: HttpMethod = .GET, progress: ProgressBlock?, completionHandler: CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, credential: credential, type: .Download(destinationDirectory), progress: progress, completionHandler: completionHandler)
    }
    
    /**
     Request to upload a file using an NURL of a local file.
     
     :param: url         the URL to upload resource into.
     :param: file        the URL of the local file to be uploaded.
     :param: parameters  the request parameters.
     :param: credential  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: method      the method to be used, by default a .POST request.
     :param: progress    a block that will be invoked to report progress during upload.
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    public func upload(url: String,  file: NSURL, parameters: [String: AnyObject]? = nil, credential: NSURLCredential? = nil, method: HttpMethod = .POST, progress: ProgressBlock?, completionHandler: CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, credential: credential, type: .Upload(.File(file)), progress: progress, completionHandler: completionHandler)
    }
    
    /**
     Request to upload a file using a raw NSData object.
     
     :param: url         the URL to upload resource into.
     :param: data        the data to be uploaded.
     :param: parameters  the request parameters.
     :param: credential  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: method       the method to be used, by default a .POST request.
     :param: progress     a block that will be invoked to report progress during upload.
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    public func upload(url: String,  data: NSData, parameters: [String: AnyObject]? = nil, credential: NSURLCredential? = nil, method: HttpMethod = .POST, progress: ProgressBlock?, completionHandler: CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, credential: credential, type: .Upload(.Data(data)), progress: progress, completionHandler: completionHandler)
    }
    
    /**
     Request to upload a file using an NSInputStream object.
     
     - parameter url:         the URL to upload resource into.
     - parameter stream:      the stream that will be used for uploading.
     - parameter parameters:  the request parameters.
     - parameter credential:  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     - parameter method:      the method to be used, by default a .POST request.
     - parameter progress:    a block that will be invoked to report progress during upload.
     - parameter completionHandler: A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    public func upload(url: String,  stream: NSInputStream,  parameters: [String: AnyObject]? = nil, credential: NSURLCredential? = nil, method: HttpMethod = .POST, progress: ProgressBlock?, completionHandler: CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, credential: credential, type: .Upload(.Stream(stream)), progress: progress, completionHandler: completionHandler)
    }
    
    
    // MARK: Private API
    
    // MARK: SessionDelegate
    class SessionDelegate: NSObject, URLSessionDelegate,  URLSessionTaskDelegate, URLSessionDataDelegate, URLSessionDownloadDelegate {
        
        fileprivate var delegates: [Int:  TaskDelegate]
        
        fileprivate subscript(task: URLSessionTask?) -> TaskDelegate? {
            get {
                guard let task = task else {
                    return nil
                }
                return self.delegates[task.taskIdentifier]
            }
            
            set (newValue) {
                guard let task = task else {
                    return
                }
                self.delegates[task.taskIdentifier] = newValue
            }
        }
        
        required override init() {
            self.delegates = Dictionary()
            super.init()
        }
        
        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
            // TODO
        }
        
        func URLSession(session: NSURLSession, didReceiveChallenge challenge: NSURLAuthenticationChallenge, completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Void) {
            completionHandler(NSURLSessionAuthChallengeDisposition.UseCredential, NSURLCredential(forTrust: challenge.protectionSpace.serverTrust!))
        }
        
        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            // TODO
        }
        
        // MARK: NSURLSessionTaskDelegate
        
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            
            if let delegate = self[task] {
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
            }
        }
        
        func URLSession(session: NSURLSession, task: NSURLSessionTask, didReceiveChallenge challenge: NSURLAuthenticationChallenge, completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Void) {
            
            if let delegate = self[task] {
                delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
            } else {
                self.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
            }
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
            if let delegate = self[task] {
                delegate.urlSession(session, task: task, needNewBodyStream: completionHandler)
            }
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            if let delegate = self[task] as? TaskUploadDelegate {
                delegate.URLSession(session, task: task, didSendBodyData: bytesSent, totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
            }
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let delegate = self[task] {
                delegate.urlSession(session, task: task, didCompleteWithError: error)
                
                self[task] = nil
            }
        }
        
        // MARK: NSURLSessionDataDelegate
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            completionHandler(.allow)
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didBecome downloadTask: URLSessionDownloadTask) {
            let downloadDelegate = TaskDownloadDelegate()
            self[downloadTask] = downloadDelegate
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if let delegate = self[dataTask] as? TaskDataDelegate {
                delegate.urlSession(session, dataTask: dataTask, didReceive: data)
            }
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping (CachedURLResponse?) -> Void) {
            completionHandler(proposedResponse)
        }
        
        // MARK: NSURLSessionDownloadDelegate
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let delegate = self[downloadTask] as? TaskDownloadDelegate {
                delegate.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
            }
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if let delegate = self[downloadTask] as? TaskDownloadDelegate {
                delegate.urlSession(session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
            }
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
            if let delegate = self[downloadTask] as? TaskDownloadDelegate {
                delegate.urlSession(session, downloadTask: downloadTask, didResumeAtOffset: fileOffset, expectedTotalBytes: expectedTotalBytes)
            }
        }
    }
    
    // MARK: NSURLSessionTaskDelegate
    class TaskDelegate: NSObject, URLSessionTaskDelegate {
        
        var data: Data? { return nil }
        var completionHandler:  ((Any?, NSError?) -> Void)?
        var responseSerializer: ResponseSerializer?
        
        var credential: NSURLCredential?
        
        func URLSession(session: NSURLSession, task: NSURLSessionTask, willPerformHTTPRedirection response: NSHTTPURLResponse, newRequest request: NSURLRequest, completionHandler: (NSURLRequest?) -> Void) {
            
            completionHandler(request)
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            var disposition: Foundation.URLSession.AuthChallengeDisposition = .performDefaultHandling
            var credential: URLCredential?
            
            if challenge.previousFailureCount > 0 {
                disposition = .cancelAuthenticationChallenge
            } else {
                credential = self.credential ?? session.configuration.urlCredentialStorage?.defaultCredential(for: challenge.protectionSpace)
                
                if credential != nil {
                    disposition = .useCredential
                }
            }
            
            completionHandler(disposition, credential)
        }
        
        
        func URLSession(session: NSURLSession, task: NSURLSessionTask, needNewBodyStream completionHandler: ((NSInputStream?) -> Void)) {
            
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if error != nil {
                completionHandler?(nil, error as NSError?)
                return
            }
            
            
            let response = task.response as! NSHTTPURLResponse
            
            if  let _ = task as? NSURLSessionDownloadTask {
                completionHandler?(response, error)
                return
            }
            
            var responseObject: Any? = nil
            do {
                if let data = data {
                    try self.responseSerializer?.validation(response, data)
                    responseObject = self.responseSerializer?.response(data, response.statusCode)
                    completionHandler?(responseObject, nil)
                }
            } catch let error as NSError {
                var userInfo = error.userInfo
                userInfo["StatusCode"] = response.statusCode
                let errorToRethrow = NSError(domain: error.domain, code: error.code, userInfo: userInfo)
                completionHandler?(responseObject, errorToRethrow)
            }
        }
    }
    
    // MARK: NSURLSessionDataDelegate
    class TaskDataDelegate: TaskDelegate, URLSessionDataDelegate {
        
        fileprivate var mutableData: NSMutableData
        
        override var data: Data? {
            return self.mutableData as Data
        }
        
        override init() {
            self.mutableData = NSMutableData()
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            completionHandler(.allow)
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.mutableData.append(data)
        }
        
        func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, willCacheResponse proposedResponse: NSCachedURLResponse, completionHandler: (NSCachedURLResponse?) -> Void) {
            let cachedResponse = proposedResponse
            completionHandler(cachedResponse)
        }
    }
    
    // MARK: NSURLSessionDownloadDelegate
    class TaskDownloadDelegate: TaskDelegate, URLSessionDownloadDelegate {
        
        var downloadProgress: ((Int64, Int64, Int64) -> Void)?
        var resumeData: Data?
        var destinationDirectory: NSString?
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let filename = downloadTask.response?.suggestedFilename
            
            // calculate final destination
            var finalDestination: URL
            if (destinationDirectory == nil) {  // use 'default documents' directory if not set
                // use default documents directory
                let documentsDirectory  = NSFileManager.defaultManager().URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask)[0] as NSURL
                finalDestination = documentsDirectory.URLByAppendingPathComponent(filename!)!
            } else {
                // check that the directory exists
                let path = destinationDirectory?.appendingPathComponent(filename!)
                finalDestination = URL(fileURLWithPath: path!)
            }
            
            do {
                try FileManager.default.moveItem(at: location, to: finalDestination)
            } catch _ {
            }
        }
        
        func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            
            self.downloadProgress?(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        }
    }
    
    // MARK: NSURLSessionTaskDelegate
    class TaskUploadDelegate: TaskDataDelegate {
        
        var uploadProgress: ((Int64, Int64, Int64) -> Void)?
        
        func URLSession(_ session: Foundation.URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            self.uploadProgress?(bytesSent, totalBytesSent, totalBytesExpectedToSend)
        }
    }
    
    // MARK: Utility methods
    public func calculateURL(baseURL: String?,  url: String) -> NSURL {
        var url = url
        if (baseURL == nil || url.hasPrefix("http")) {
            return URL(string: url)!
        }
        
        guard let finalURL = URL(string: baseURL!) else {return nil}
        if (url.hasPrefix("/")) {
            url = url.substring(from: url.characters.index(url.startIndex, offsetBy: 1))
        }
        
        return finalURL.URLByAppendingPathComponent(url)!;
    }
    
    func hasMultiPartData(httpParams parameters: [String: Any]?) -> Bool {
        if (parameters == nil) {
            return false
        }
        
        var isMultiPart = false
        for (_, value) in parameters! {
            if value is MultiPartData {
                isMultiPart = true
                break
            }
        }
        
        return isMultiPart
    }
}
