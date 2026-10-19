import Foundation
@main struct Tests {
    static func main() async {
        for url in ["localhost:8796", "127.0.0.1:8796", "http://[::1]:8796", "http://127.1.2.3:8080/path"] { precondition(LocalURL.parse(url) != nil, url) }
        for url in ["https://example.com", "http://127.0.0.1.evil.com", "file:///tmp/a", "http://192.168.1.1", "http://user:pass@localhost", "http://127.0.0.999", "http://localhost:99999"] { precondition(LocalURL.parse(url) == nil, url) }
        precondition(Network.title("<TITLE>Project &amp; Test</TITLE>") == "Project & Test")
        let ok = await Network.probe("http://127.0.0.1:18796/")
        precondition(ok.healthy && ok.title == "LocalWatch Test")
        let bad = await Network.probe("http://127.0.0.1:18796/error")
        precondition(bad.online && !bad.healthy && bad.code == 503)
        let redirect = await Network.probe("http://127.0.0.1:18796/redirect")
        precondition(redirect.code == 302, "Redirect must not leave the local machine")
        let dead = await Network.probe("http://127.0.0.1:18797/")
        precondition(!dead.online)
        precondition(Network.listeningPorts().contains(18796))
        print("PASS: local URL validation, titles, HTTP 200/503, redirect boundary, offline, listener discovery")
    }
}
