#!/usr/bin/env python3
"""Exercise generated TLS vhosts and Host forwarding using real local Nginx.

Requires bash, jq, envsubst, openssl and nginx. Uses temporary files and random
loopback ports; does not install configuration or reload the system service.
"""
import http.server
import os
from pathlib import Path
import re
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class Backend(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.headers['Host'].encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


project = Path(__file__).resolve().parent.parent
nginx = shutil.which('nginx')
if not nginx:
    raise SystemExit('nginx is required')
version = subprocess.run([nginx, '-v'], capture_output=True, text=True, check=True)
old_nginx = tuple(map(int, re.search(r'nginx/(\d+)\.(\d+)', version.stderr).groups())) < (1, 25)

with tempfile.TemporaryDirectory(prefix='turboflare-nginx-') as tmp:
    root = Path(tmp)
    shutil.copytree(project / 'scripts', root / 'scripts')
    shutil.copytree(project / 'templates', root / 'templates')
    backend = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Backend)
    thread = threading.Thread(target=backend.serve_forever, daemon=True)
    thread.start()
    tls_port, http_port = free_port(), free_port()
    fixture = (project / '.env.example').read_text()
    fixture += f'\nDOMAIN=meowbot.lol,meowow.lol\nNGINX_INTERNAL_PORT={tls_port}\nXRAY_XHTTP_PORT={backend.server_port}\n'
    (root / '.env').write_text(fixture)
    subprocess.run(['bash', str(root / 'scripts/render.sh'), '--only', 'turboflare'], check=True, stdout=subprocess.DEVNULL)
    sites = []
    for domain in ['meowbot.lol', 'meowow.lol']:
        certdir = root / 'ssl' / domain
        certdir.mkdir(parents=True)
        subprocess.run(['openssl', 'req', '-x509', '-nodes', '-newkey', 'rsa:2048', '-days', '1',
                        '-keyout', str(certdir/'origin.key'), '-out', str(certdir/'origin.crt'),
                        '-subj', f'/CN={domain}', '-addext', f'subjectAltName=DNS:{domain}'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        site = (root / 'build/turboflare' / domain / 'nginx-site.conf').read_text()
        site = site.replace('listen 80;', f'listen 127.0.0.1:{http_port};')
        site = site.replace('/etc/nginx/ssl/', str(root/'ssl') + '/')
        site = site.replace('/var/log/nginx/', str(root) + '/')
        site = site.replace('/var/www/turboflare-cover', str(root))
        if old_nginx:
            # Same TLS-vhost test on Ubuntu's 1.24; only HTTP/2 syntax differs.
            site = site.replace('    http2 on;\n', '').replace('ssl proxy_protocol;', 'ssl http2 proxy_protocol;')
        target = root / f'{domain}.conf'
        target.write_text(site)
        sites.append(f'include {target};')
    config = root / 'nginx.conf'
    config.write_text(f'''daemon off;
master_process off;
pid {root}/nginx.pid;
error_log {root}/error.log;
events {{ worker_connections 128; }}
http {{
  access_log off;
  client_body_temp_path {root}/body;
  proxy_temp_path {root}/proxy;
  fastcgi_temp_path {root}/fastcgi;
  uwsgi_temp_path {root}/uwsgi;
  scgi_temp_path {root}/scgi;
  {os.linesep.join(sites)}
}}
''')
    subprocess.run([nginx, '-t', '-p', str(root)+'/', '-c', str(config)], check=True)
    proc = subprocess.Popen([nginx, '-p', str(root)+'/', '-c', str(config)])
    try:
        for _ in range(50):
            if proc.poll() is not None:
                raise RuntimeError((root/'error.log').read_text())
            try:
                with socket.create_connection(('127.0.0.1', tls_port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.1)
        for domain in ['meowbot.lol', 'meowow.lol']:
            ctx = ssl.create_default_context(cafile=str(root/'ssl'/domain/'origin.crt'))
            with socket.create_connection(('127.0.0.1', tls_port), timeout=5) as sock:
                sock.sendall(f'PROXY TCP4 127.0.0.1 127.0.0.1 12345 {tls_port}\r\n'.encode())
                with ctx.wrap_socket(sock, server_hostname=domain) as tls:
                    tls.sendall(f'GET /static/getFile/video/segment.ts HTTP/1.1\r\nHost: {domain}\r\nConnection: close\r\n\r\n'.encode())
                    response = b''
                    while data := tls.recv(8192):
                        response += data
            assert response.startswith(b'HTTP/1.1 200'), response
            assert response.split(b'\r\n\r\n', 1)[1] == b'meowbot.lol', response
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        backend.shutdown()
        backend.server_close()
print('PASS: both domains select their own TLS certificate and forward the primary Host to the shared backend')
