import AEXML
import Alamofire
import Foundation
import ReactiveSwift
import QLog

func buildFinalSPRequest(body: AEXMLDocument, idpRequestData: IdpRequestData) throws -> URLRequest {
    QLogDebug("IDP SOAP response:")
    QLogDebug(body.xml)
    guard let soapNamespace = body.root.name.split(separator: ":").first?.description else {
        QLogError("Cannot get SOAP namespace")
        throw ECPError.soapGeneration
    }
    guard let acuString = body.root["\(soapNamespace):Header"]["ecp:Response"].attributes["AssertionConsumerServiceURL"],
          let assertionConsumerServiceURL = URL(string: acuString)
            else {
        throw ECPError.assertionConsumerServiceURL
    }
    QLogDebug("Found AssertionConsumerServiceURL in IdP SOAP response.")

    /**
        Make a new SOAP envelope with the following:
        - (optional) A SOAP Header containing the RelayState from the first SP response
        - The SOAP body of the IDP response
    */
    let spSoapDocument = AEXMLDocument()

    // XML namespaces are just...lovely
    let spSoapAttributes = [
        "xmlns:S": "http://schemas.xmlsoap.org/soap/envelope/",
        "xmlns:\(soapNamespace)": "http://schemas.xmlsoap.org/soap/envelope/"
    ]
    let envelope = spSoapDocument.addChild(
            name: "\(soapNamespace):Envelope",
            attributes: spSoapAttributes
    )

    // Bail out if these don't match
    guard idpRequestData.responseConsumerURL.absoluteString == assertionConsumerServiceURL.absoluteString else {
        if let request = buildSoapFaultRequest(URL: idpRequestData.responseConsumerURL, error: ECPError.security) {
            sendSpSoapFaultRequest(request: request)
        }
        throw ECPError.security
    }

    if let relay = idpRequestData.relayState {
        let header = envelope.addChild(name: "\(soapNamespace):Header")
        header.addChild(relay)
        QLogDebug("Added RelayState to the SOAP header for the final SP request.")
    }

    let extractedBody = body.root["\(soapNamespace):Body"]
    envelope.addChild(extractedBody)
    let soapString = spSoapDocument.root.xml//String(trimWhiteSpace: false, format: false)
    guard let soapData = soapString.data(using: String.Encoding.utf8) else {
        throw ECPError.soapGeneration
    }
    QLogDebug("Sending this SOAP to the SP:")
    QLogDebug(spSoapDocument.root.xml)

    var spReq = URLRequest(url: assertionConsumerServiceURL)
    spReq.httpMethod = "POST"
    spReq.httpBody = soapData
    spReq.setValue("application/vnd.paos+xml", forHTTPHeaderField: "Content-Type")
    spReq.timeoutInterval = 10
    QLogDebug("Built final SP request.")
    return spReq
}

func sendFinalSPRequest(document: AEXMLDocument, idpRequestData: IdpRequestData) -> SignalProducer<String, Error> {
    return SignalProducer { observer, _ in
        do {
            let request = try buildFinalSPRequest(body: document, idpRequestData: idpRequestData)
            let req = AF.request(request)
            req.responseString(errorOnNil: false).map {
                $0.value
            }.start { event in
                switch event {
                case .value(let value):
                    observer.send(value: value)
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
