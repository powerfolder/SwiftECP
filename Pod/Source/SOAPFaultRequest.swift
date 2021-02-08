import AEXML
import Alamofire
import Foundation
import QLog

// Something the spec wants but we don't need. Fire and forget.
func sendSpSoapFaultRequest(request: URLRequest) {
    let request = AF.request(request)
    request.responseString { response in
        switch response.result {
        case .success(let value):
            QLogDebug(value)
        case .failure(let error):
            QLogWarning(error.localizedDescription)
        }
    }
}

func buildSoapFaultBody(error: Error) -> Data? {
    let soapDocument = AEXMLDocument()
    let soapAttribute = ["xmlns:SOAP-ENV": "http://schemas.xmlsoap.org/soap/envelope/"]
    let envelope = soapDocument.addChild(name: "SOAP-ENV:Envelope", attributes: soapAttribute)
    let body = envelope.addChild(name: "SOAP-ENV:Body")
    let fault = body.addChild(name: "SOAP-ENV:Fault")
    fault.addChild(name: "faultcode", value: String(describing: error))
    fault.addChild(name: "faultstring", value: error.localizedDescription)
    return soapDocument.xml.data(using: .utf8)//(trimWhiteSpace: false, format: false).data(using: .utf8)
}

func buildSoapFaultRequest(URL: URL, error: Error) -> URLRequest? {
    if let body = buildSoapFaultBody(error: error) {
        var request = URLRequest(url: URL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/vnd.paos+xml", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        return request
    }
    return nil
}
