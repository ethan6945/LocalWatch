from http.server import HTTPServer, BaseHTTPRequestHandler
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503 if self.path == '/error' else 302 if self.path == '/redirect' else 200)
        self.send_header('Content-Type','text/html')
        if self.path == '/redirect': self.send_header('Location','https://example.com')
        self.end_headers()
        self.wfile.write(b'<title>LocalWatch Test</title>')
    def log_message(self, *args): pass
HTTPServer(('127.0.0.1',18796),Handler).serve_forever()
