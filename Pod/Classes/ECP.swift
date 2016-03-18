import Foundation
import Alamofire
import AEXML
import ReactiveCocoa
import XCGLogger

func basicAuthHeader(username: String, password: String) -> String? {
    let encodedUsernameAndPassword = ("\(username):\(password)" as NSString)
        .dataUsingEncoding(NSASCIIStringEncoding)?
        .base64EncodedStringWithOptions([])
    guard encodedUsernameAndPassword != nil else {
        return nil
    }
    return "Basic \(encodedUsernameAndPassword)"
}

public class ECP {

	let log = XCGLogger.defaultInstance()
	
	public init(
        logLevel: XCGLogger.LogLevel
    ) {
		log.setup(
			logLevel,
			showLogLevel: true,
			showFileNames: true,
			showLineNumbers: true,
			writeToFile: nil,
			fileLogLevel: nil
		)
	}
	
	struct IdpRequestData {
		let request: NSMutableURLRequest
		let responseConsumerURL: NSURL
		let relayState: AEXMLElement?
	}

    public func login(protectedURL: NSURL, username: String, password: String) -> SignalProducer<String, NSError> {
        let req = Alamofire.request(self.buildInitialRequest(protectedURL))
        return req.responseXML()
        .flatMap(.Concat) { self.sendIdpRequest($0.value, username: username, password: password) }
        .flatMap(.Concat) { self.sendSpRequest($0.0.value, idpRequestData: $0.1) }
    }

    func sendIdpRequest(
        initialSpResponse: AEXMLDocument,
        username: String,
        password: String
    ) -> SignalProducer<(CheckedResponse<AEXMLDocument>, IdpRequestData), NSError> {
        return SignalProducer { observer, disposable in
            do {
                let idpRequestData = try self.buildIdpRequest(initialSpResponse, username: username, password: password)
                let req = Alamofire.request(idpRequestData.request)
                req.responseString().map { ($0, idpRequestData) }.start { [weak self] event in
                    switch event {
                    case .Next(let value):

                        let stringResponse = value.0

                        guard case 200 ... 299 = stringResponse.response.statusCode else {
                            self?.log.debug("Received \(stringResponse.response.statusCode) response from IdP")
                            observer.sendFailed(Error.IdpRequestFailed.error)
                            break
                        }

                        guard let responseData = stringResponse.value.dataUsingEncoding(NSUTF8StringEncoding) else {
                            observer.sendFailed(Error.XMLSerialization.error)
                            break
                        }

                        guard let responseXML = try? AEXMLDocument(xmlData: responseData) else {
                            observer.sendFailed(Error.XMLSerialization.error)
                            break
                        }

                        let xmlResponse = CheckedResponse<AEXMLDocument>(
                            request: stringResponse.request,
                            response: stringResponse.response,
                            value: responseXML
                        )

                        observer.sendNext((xmlResponse, value.1))
                        observer.sendCompleted()

                    case .Failed(let error):
                        observer.sendFailed(error)
                    default:
                        break
                    }
                }
            } catch {
                observer.sendFailed(error as NSError)
            }
        }
    }

    func sendSpRequest(
        document: AEXMLDocument,
        idpRequestData: IdpRequestData
    ) -> SignalProducer<String, NSError> {
        return SignalProducer { observer, disposable in
            do {
                let request = try self.buildSpRequest(
                    document,
                    idpRequestData: idpRequestData
                )

                let req = Alamofire.request(request)
                req.responseString(false).map { $0.value }.start { event in
                    switch event {
                    case .Next(let value):
                        observer.sendNext(value)
                        observer.sendCompleted()
                    case .Failed(let error):
                        observer.sendFailed(error)
                    default:
                        break
                    }
                }
            } catch {
                observer.sendFailed(error as NSError)
            }
        }
    }

    func buildInitialRequest(protectedURL: NSURL) -> NSMutableURLRequest {
        // Create a request with the appropriate headers to trigger ECP on the SP.
        let request = NSMutableURLRequest(URL: protectedURL)
        request.setValue(
            "text/html; application/vnd.paos+xml",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "ver=\"urn:liberty:paos:2003-08\";\"urn:oasis:names:tc:SAML:2.0:profiles:SSO:ecp\"",
            forHTTPHeaderField: "PAOS"
        )
        request.timeoutInterval = 10
        log.debug("Built initial SP request.")
        return request
    }

    func buildIdpRequest(body: AEXMLDocument, username: String, password: String) throws -> IdpRequestData {
        log.debug("Initial SP SOAP response:")
        log.debug(body.xmlString)

        // Remove the XML signature
        body.root["S:Body"]["samlp:AuthnRequest"]["ds:Signature"].removeFromParent()
        log.debug("Removed the XML signature from the SP SOAP response.")
        
        // Store this so we can compare it against the AssertionConsumerServiceURL from the IdP
        let responseConsumerURLString = body.root["S:Header"]["paos:Request"]
            .attributes["responseConsumerURL"]

        guard let
            rcuString = responseConsumerURLString,
            responseConsumerURL = NSURL(string: rcuString)
        else {
            throw Error.ResponseConsumerURL
        }

        log.debug("Found the ResponseConsumerURL in the SP SOAP response.")
        
        // Get the SP request's RelayState for later
        // This may or may not exist depending on the SP/IDP
        let relayState = body.root["S:Header"]["ecp:RelayState"].first
        
        if relayState != nil {
            log.debug("SP SOAP response contains RelayState.")
        } else {
            log.warning("No RelayState present in the SP SOAP response.")
        }
        
        // Get the IdP's URL
        let idpURLString = body.root["S:Body"]["samlp:AuthnRequest"]["samlp:Scoping"]["samlp:IDPList"]["samlp:IDPEntry"]
            .attributes["ProviderID"]

        guard let
            idp = idpURLString,
            idpURL = NSURL(string: idp),
            idpHost = idpURL.host,
            idpEcpURL = NSURL(string: "https://\(idpHost)/idp/profile/SAML2/SOAP/ECP")
        else {
            throw Error.IdpExtraction
        }

        log.debug("Found IdP URL in the SP SOAP response.")
        // Make a new SOAP envelope with the SP's SOAP body only
        let body = body.root["S:Body"]
        let soapDocument = AEXMLDocument()
        let soapAttributes = [
            "xmlns:S": "http://schemas.xmlsoap.org/soap/envelope/"
        ]
        let envelope = soapDocument.addChild(
            name: "S:Envelope",
            attributes: soapAttributes
        )
        envelope.addChild(body)

        guard let soapString = envelope.xmlString.dataUsingEncoding(NSUTF8StringEncoding) else {
            throw Error.SoapGeneration
        }

        guard let authorizationHeader = basicAuthHeader(username, password: password) else {
            throw Error.MissingBasicAuth
        }

        log.debug("Sending this SOAP to the IDP:")
        log.debug(envelope.xmlString)

        let idpReq = NSMutableURLRequest(URL: idpEcpURL)
        idpReq.HTTPMethod = "POST"
        idpReq.HTTPBody = soapString
        idpReq.setValue(
            "application/vnd.paos+xml",
            forHTTPHeaderField: "Content-Type"
        )
        idpReq.setValue(
            authorizationHeader,
            forHTTPHeaderField: "Authorization"
        )
        log.debug(authorizationHeader)
        idpReq.timeoutInterval = 10
        log.debug("Built first IdP request.")
        
        return IdpRequestData(
            request: idpReq,
            responseConsumerURL: responseConsumerURL,
            relayState: relayState
        )
	}
	
    func buildSpRequest(body: AEXMLDocument, idpRequestData: IdpRequestData) throws -> NSMutableURLRequest {
        log.debug("IDP SOAP response:")
        log.debug(body.xmlString)

        guard let
            acuString = body.root["soap11:Header"]["ecp:Response"]
                .attributes["AssertionConsumerServiceURL"],
            assertionConsumerServiceURL = NSURL(string: acuString)
        else {
            throw Error.AssertionConsumerServiceURL
        }

        log.debug("Found AssertionConsumerServiceURL in IdP SOAP response.")
        
        // Make a new SOAP envelope with the following:
        //     - (optional) A SOAP Header containing the RelayState from the first SP response
        //     - The SOAP body of the IDP response
        let spSoapDocument = AEXMLDocument()
        
        // XML namespaces are just...lovely
        let spSoapAttributes = [
            "xmlns:S": "http://schemas.xmlsoap.org/soap/envelope/",
            "xmlns:soap11": "http://schemas.xmlsoap.org/soap/envelope/"
        ]
        let envelope = spSoapDocument.addChild(
            name: "S:Envelope",
            attributes: spSoapAttributes
        )

        // Bail out if these don't match
        guard
            idpRequestData.responseConsumerURL.URLString ==
                assertionConsumerServiceURL.URLString
            else {
                if let request = buildSoapFaultRequest(
                    idpRequestData.responseConsumerURL,
                    error: Error.Security.error
                    ) {
                        sendSpSoapFaultRequest(request)
                }
                throw Error.Security
        }

        if let relay = idpRequestData.relayState {
            let header = envelope.addChild(name: "S:Header")
            header.addChild(relay)
            log.debug("Added RelayState to the SOAP header for the final SP request.")
        }
        
        let extractedBody = body.root["soap11:Body"]
        envelope.addChild(extractedBody)

        guard let bodyData = envelope.xmlString.dataUsingEncoding(NSUTF8StringEncoding) else {
            throw Error.SoapGeneration
        }

        log.debug("Sending this SOAP to the SP:")
        log.debug(envelope.xmlString)

        let spReq = NSMutableURLRequest(URL: assertionConsumerServiceURL)
        spReq.HTTPMethod = "POST"
        spReq.HTTPBody = bodyData
        spReq.setValue(
            "application/vnd.paos+xml",
            forHTTPHeaderField: "Content-Type"
        )
        spReq.timeoutInterval = 10

        log.debug("Built final SP request.")
        return spReq
	}
	
	// Something the spec wants but we don't need. Fire and forget.
	func sendSpSoapFaultRequest(request: NSMutableURLRequest) {
		let request = Alamofire.request(request)
        request.responseString { response in
            if let value = response.result.value {
                self.log.debug(value)
            } else if let error = response.result.error {
                self.log.warning(error.localizedDescription)
            }
        }
	}

	func buildSoapFaultBody(error: NSError) -> NSData? {
		let soapDocument = AEXMLDocument()
		let soapAttribute = [
			"xmlns:SOAP-ENV": "http://schemas.xmlsoap.org/soap/envelope/"
		]
		let envelope = soapDocument.addChild(
			name: "SOAP-ENV:Envelope",
			attributes: soapAttribute
		)
		let body = envelope.addChild(name: "SOAP-ENV:Body")
		let fault = body.addChild(name: "SOAP-ENV:Fault")
		fault.addChild(name: "faultcode", value: String(error.code))
		fault.addChild(name: "faultstring", value: error.localizedDescription)
		return soapDocument.xmlString.dataUsingEncoding(NSUTF8StringEncoding)
	}
	
	func buildSoapFaultRequest(URL: NSURL, error: NSError) -> NSMutableURLRequest? {
		if let body = buildSoapFaultBody(error) {
			let request = NSMutableURLRequest(URL: URL)
			request.HTTPMethod = "POST"
			request.HTTPBody = body
			request.setValue(
				"application/vnd.paos+xml",
				forHTTPHeaderField: "Content-Type"
			)
			request.timeoutInterval = 10

			return request
		}
		return nil
	}
	
	enum Error: ErrorType {
		case Extraction
		case EmptyBody
		case SoapGeneration
		case IdpExtraction
		case RelayState
		case ResponseConsumerURL
		case AssertionConsumerServiceURL
		case Security
		case MissingBasicAuth
		case WTF
        case IdpRequestFailed
        case XMLSerialization
		
		private var domain: String {
			return "edu.clemson.swiftecp"
		}
		
		private var errorCode: Int {
			switch self {
			case .Extraction:
				return 200
			case .EmptyBody:
				return 201
			case .SoapGeneration:
				return 202
			case .IdpExtraction:
				return 203
			case .RelayState:
				return 204
			case .ResponseConsumerURL:
				return 205
			case .AssertionConsumerServiceURL:
				return 206
			case .Security:
				return 207
			case .MissingBasicAuth:
				return 208
			case .WTF:
				return 209
            case .IdpRequestFailed:
                return 210
            case .XMLSerialization:
                return 211
			}
		}
		
		var userMessage: String {
			switch self {
			case .EmptyBody:
				return "The password you entered is incorrect. Please try again."
            case .IdpRequestFailed:
                return "The password you entered is incorrect. Please try again."
			default:
				return "An unknown error occurred. Please let us know how you arrived at this error and we will fix the problem as soon as possible."
			}
		}
		
		var description: String {
			switch self {
			case .Extraction:
				return "Could not extract the necessary info from the XML response."
			case .EmptyBody:
				return "Empty body. The given password is likely incorrect."
			case .SoapGeneration:
				return "Could not generate a valid SOAP request body from the response's SOAP body."
			case .IdpExtraction:
				return "Could not extract the IDP endpoint from the SOAP body."
			case .RelayState:
				return "Could not extract the RelayState from the SOAP body."
			case .ResponseConsumerURL:
				return "Could not extract the ResponseConsumerURL from the SOAP body."
			case .AssertionConsumerServiceURL:
				return "Could not extract the AssertionConsumerServiceURL from the SOAP body."
			case .Security:
				return "ResponseConsumerURL did not match AssertionConsumerServiceURL."
			case .MissingBasicAuth:
				return "Could not generate basic auth from the given username and password."
			case .WTF:
				return "Unknown error. Please contact the library developer."
            case .IdpRequestFailed:
                return "IdP request failed. The given password is likely incorrect."
            case .XMLSerialization:
                return "Unable to serialize response to XML."
			}
		}
		
		var error: NSError {
			return NSError(domain: domain, code: errorCode, userInfo: [
				NSLocalizedDescriptionKey: userMessage,
				NSLocalizedFailureReasonErrorKey: description
			])
		}
	}
}