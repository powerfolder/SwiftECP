import Foundation
import QLog

func buildInitialSPRequest(protectedURL: URL) -> URLRequest {
    // Create a request with the appropriate headers to trigger ECP on the SP.
    var request = URLRequest(url: protectedURL)
    request.setValue("text/html; application/vnd.paos+xml", forHTTPHeaderField: "Accept")
    request.setValue("ver=\"urn:liberty:paos:2003-08\";\"urn:oasis:names:tc:SAML:2.0:profiles:SSO:ecp\"", forHTTPHeaderField: "PAOS")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.timeoutInterval = 10
    QLogDebug("Built initial SP request.")
    return request
}
