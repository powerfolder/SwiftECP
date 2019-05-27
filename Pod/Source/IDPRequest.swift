import AEXML
import Alamofire
import Foundation
import ReactiveSwift
import QLog

func basicAuthHeader(username: String, password: String) -> String? {
    let encodedUsernameAndPassword = ("\(username):\(password)").data(using: .ascii)?.base64EncodedString()
    guard encodedUsernameAndPassword != nil else {
        return nil
    }
    return "Basic \(encodedUsernameAndPassword!)"
}

func buildIdpRequest(body: AEXMLDocument, username: String, password: String, idpEcpURL: URL) throws -> IdpRequestData {
    QLogDebug("Initial SP SOAP response:")
    QLogDebug(body.xml)

    // Remove the XML signature
    // Disabled - not sure if this needs to be optional for some setups
    //    body.root["S:Body"]["samlp:AuthnRequest"]["ds:Signature"].removeFromParent()
    //    QLogDebug("Removed the XML signature from the SP SOAP response.")

    // Store this so we can compare it against the AssertionConsumerServiceURL from the IdP
    let responseConsumerURLString = body.root["S:Header"]["paos:Request"]
            .attributes["responseConsumerURL"]

    guard let rcuString = responseConsumerURLString,
          let responseConsumerURL = URL(string: rcuString)
            else {
        throw ECPError.responseConsumerURL
    }
    QLogDebug("Found the ResponseConsumerURL in the SP SOAP response.")

    // Get the SP request's RelayState for later
    // This may or may not exist depending on the SP/IDP
    let relayState = body.root["S:Header"]["ecp:RelayState"].first
    if relayState != nil {
        QLogDebug("SP SOAP response contains RelayState.")
    } else {
        QLogDebug("No RelayState present in the SP SOAP response.")
    }

    // Get the IdP's URL
    let idpURLString = body.root["S:Body"]["samlp:AuthnRequest"]["samlp:Scoping"]["samlp:IDPList"]["samlp:IDPEntry"].attributes["ProviderID"]
    guard let
          idp = idpURLString,
          let idpURL = URL(string: idp),
          let idpHost = idpURL.host
            else {
        throw ECPError.idpExtraction
    }

    QLogDebug("Found IdP URL in the SP SOAP response.")
    // Make a new SOAP envelope with the SP's SOAP body only
    let body = body.root["S:Body"]
    let soapDocument = AEXMLDocument()
    let soapAttributes = ["xmlns:S": "http://schemas.xmlsoap.org/soap/envelope/"]
    let envelope = soapDocument.addChild(name: "S:Envelope", attributes: soapAttributes)
    envelope.addChild(body)
    let soapString = envelope.xmlString(trimWhiteSpace: false, format: false)
    guard let soapData = soapString.data(using: String.Encoding.utf8) else {
        throw ECPError.soapGeneration
    }
    guard let authorizationHeader = basicAuthHeader(username: username, password: password) else {
        throw ECPError.missingBasicAuth
    }
    QLogDebug("Sending this SOAP to the IDP:")
    QLogDebug(envelope.xml)

    var idpReq = URLRequest(url: idpEcpURL)
    idpReq.httpMethod = "POST"
    idpReq.httpBody = soapData
    idpReq.setValue("text/xml; charset=\"UTF-8\"", forHTTPHeaderField: "Content-Type")

    idpReq.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    idpReq.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")

    QLogDebug(authorizationHeader)
    idpReq.timeoutInterval = 10

    QLogDebug("Built first IdP request.")

    return IdpRequestData(request: idpReq, responseConsumerURL: responseConsumerURL, relayState: relayState)
}

func sendIdpRequest(initialSpResponse: AEXMLDocument, username: String, password: String, idpEcpURL: URL) -> SignalProducer<(CheckedResponse<AEXMLDocument>, IdpRequestData), Error> {
    return SignalProducer { observer, _ in
        do {
            let idpRequestData = try buildIdpRequest(body: initialSpResponse, username: username, password: password, idpEcpURL: idpEcpURL)
            let req = Alamofire.request(idpRequestData.request)
            req.responseString().map {
                ($0, idpRequestData)
            }.start { event in
                switch event {
                case let .value(value):
                    let stringResponse = value.0
                    guard case 200...299 = stringResponse.response.statusCode else {
                        QLogDebug("Received \(stringResponse.response.statusCode) response from IdP")
                        observer.send(error: ECPError.idpRequestFailed)
                        break
                    }
                    guard let responseData = stringResponse.value.data(using: String.Encoding.utf8) else {
                        observer.send(error: ECPError.xmlSerialization)
                        break
                    }
                    guard let responseXML = try? AEXMLDocument(xml: responseData) else {
                        observer.send(error: ECPError.xmlSerialization)
                        break
                    }
                    let xmlResponse = CheckedResponse<AEXMLDocument>(request: stringResponse.request, response: stringResponse.response, value: responseXML)
                    observer.send(value: (xmlResponse, value.1))
                    observer.sendCompleted()
                case .failed(let error):
                    observer.send(error: error)
                default:
                    break
                }
            }
        } catch {
            observer.send(error: error)
        }
    }
}
