"""Local-only HTTPS entrypoint for the production MacBlock server."""
import os
import ssl
import sys
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))
import server as macblock

if __name__ == "__main__":
    cert = os.environ["MACBLOCK_DEV_CERT"]
    key = os.environ["MACBLOCK_DEV_KEY"]
    macblock.init_db()
    httpd = ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("PORT", "18443"))), macblock.Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=cert, keyfile=key)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    print("MacBlock dev HTTPS listening on https://localhost:" + os.environ.get("PORT", "18443"), flush=True)
    httpd.serve_forever()
