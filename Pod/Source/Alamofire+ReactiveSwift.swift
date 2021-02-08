import AEXML
import Alamofire
import Foundation
import ReactiveSwift

public struct CheckedResponse<T> {

    let request: URLRequest
    let response: HTTPURLResponse
    let value: T

}

extension DataRequest {

    @discardableResult
    public func responseXML(queue: DispatchQueue? = nil, completionHandler: @escaping (AEXMLDocument?, Error?, AFDataResponse<Data?>) -> Void) -> Self {
        return response { response in
            switch response.result {
                case .success(let value):

                    guard let data = value else {
                        return completionHandler(nil, AlamofireRACError.xmlSerialization, response)
                    }

                    do {
                        let document = try AEXMLDocument(xml: data)
                        completionHandler(document, nil, response)
                    } catch {
                        completionHandler(nil, AlamofireRACError.xmlSerialization, response)
                    }

                case .failure(let error):
                    completionHandler(nil, error, response)
            }
        }
    }

    @discardableResult
    public func responseStringEmptyAllowed(queue: DispatchQueue? = nil, completionHandler: @escaping (String?, Error?, AFDataResponse<String>?) -> Void) -> Self {

        return responseString { response in
            switch response.result {
                case .success(let value):
                    completionHandler(value, nil, response)
                case .failure(let error):
                    completionHandler(nil, AlamofireRACError.network(error: error), response)
            }
        }
    }

    public func responseXML() -> SignalProducer<CheckedResponse<AEXMLDocument>, Error> {
        return SignalProducer { observer, _ in
            self.responseXML { doc, error, response in

                if let error = error {
                    observer.send(error: error)
                    return
                }

                guard let req = response.request, let resp = response.response, let doc = doc else {
                    return observer.send(error: AlamofireRACError.incompleteResponse)
                }

                observer.send(value: CheckedResponse<AEXMLDocument>(request: req, response: resp, value: doc))
                observer.sendCompleted()
            }
        }
    }

//    public func responseXML() -> SignalProducer<CheckedResponse<AEXMLDocument>, Error> {
//            return SignalProducer { observer, _ in
//                self.responseXML { response in
//                    if let error = response.result.error {
//                        return observer.send(error: error)
//                    }
//                    guard let document = response.result.value else {
//                        return observer.send(error: AlamofireRACError.xmlSerialization)
//                    }
//                    guard let request = response.request, let response = response.response else {
//                        return observer.send(error: AlamofireRACError.incompleteResponse)
//                    }
//                    observer.send(value: CheckedResponse<AEXMLDocument>(request: request, response: response, value: document))
//                    observer.sendCompleted()
//                }
//            }
//        }

    public func responseString(errorOnNil: Bool = true) -> SignalProducer<CheckedResponse<String>, Error> {
        return SignalProducer { observer, _ in
            self.responseStringEmptyAllowed { stringResult, error, response in

                if let error = error {
                    observer.send(error: error)
                    return
                }

                guard let req = response?.request, let resp = response?.response, let value = stringResult else {
                    return observer.send(error: AlamofireRACError.incompleteResponse)
                }

                if errorOnNil && value.count == 0 {
                    observer.send(error: AlamofireRACError.incompleteResponse)
                    return
                }

                observer.send(value: CheckedResponse<String>(request: req, response: resp, value: value))
                observer.sendCompleted()
            }
        }
    }
}

public enum AlamofireRACError: Error {

    case network(error: Error?)
    case dataSerialization(error: Error?)
    case xmlSerialization
    case incompleteResponse
    case unknownError

    public var description: String {
        switch self {
        case .network(let error):
            return "There was a network issue: \(String(describing: error))."
        case .dataSerialization(let error):
            return "Could not serialize data: \(String(describing: error))."
        case .xmlSerialization:
            return "Could not serialize XML."
        case .incompleteResponse:
            return "Incomplete response."
        default:
            return "There was an unknown error."
        }
    }

}
