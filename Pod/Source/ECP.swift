import AEXML
import Alamofire
import Foundation
import ReactiveSwift

struct IdpRequestData {

    let request: URLRequest
    let responseConsumerURL: URL
    let relayState: AEXMLElement?

}

public func ECPLogin(protectedURL: URL, username: String, password: String) -> SignalProducer<String, Error> {
    return Alamofire.request(buildInitialSPRequest(protectedURL: protectedURL))
            .responseXML()
            .flatMap(.concat) {
                sendIdpRequest(initialSpResponse: $0.value, username: username, password: password)
            }
            .flatMap(.concat) {
                sendFinalSPRequest(document: $0.0.value, idpRequestData: $0.1)
            }
}
