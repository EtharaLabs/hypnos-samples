import http.server, sys, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        ct = q.get("ct", ["application/x-zork"])[0]
        body = bytes.fromhex(q["hex"][0]) if "hex" in q else q.get("body", ["a;b;c;d;e"])[0].encode()
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
