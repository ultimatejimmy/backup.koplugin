#!/usr/bin/env python3
"""
tools/test_live_servers.py
On-demand local integration test runner for KOReader Backup.
Spins up lightweight, zero-dependency in-process WebDAV and FTP servers on 127.0.0.1,
executes live protocol connection tests, file uploads, directory listings,
downloads, and deletions, and tears down cleanly.
"""

import os
import sys
import time
import socket
import tempfile
import shutil
import threading
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
import socketserver
import base64
import urllib.parse
from xml.sax.saxutils import escape

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

# -----------------------------------------------------------------------------
# 1. Zero-Dependency In-Process WebDAV Server
# -----------------------------------------------------------------------------
class WebDAVRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # Suppress noisy HTTP request logging unless DEBUG is enabled
        if os.environ.get("DEBUG_SERVERS"):
            super().log_message(format, *args)

    def get_fs_path(self):
        root = self.server.root_dir
        path = urllib.parse.unquote(self.path.split("?")[0])
        rel_path = path.lstrip("/\\")
        return os.path.normpath(os.path.join(root, rel_path))

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("DAV", "1, 2")
        self.send_header("MS-Author-Via", "DAV")
        self.send_header("Allow", "OPTIONS, GET, HEAD, POST, PUT, DELETE, PROPFIND, MKCOL")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PROPFIND(self):
        fs_path = self.get_fs_path()
        if not os.path.exists(fs_path):
            self.send_error(404, "Not Found")
            return

        xml_entries = []
        req_path = urllib.parse.unquote(self.path.split("?")[0])
        if not req_path.endswith("/") and os.path.isdir(fs_path):
            req_path += "/"

        def add_entry(entry_href, is_collection, size, mtime):
            resourcetype = "<D:resourcetype><D:collection/></D:resourcetype>" if is_collection else "<D:resourcetype/>"
            xml_entries.append(f"""  <D:response>
    <D:href>{escape(entry_href)}</D:href>
    <D:propstat>
      <D:prop>
        {resourcetype}
        <D:getcontentlength>{size}</D:getcontentlength>
        <D:getlastmodified>{time.strftime('%a, %d %b %Y %H:%M:%S GMT', time.gmtime(mtime))}</D:getlastmodified>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>""")

        st = os.stat(fs_path)
        add_entry(req_path, os.path.isdir(fs_path), st.st_size if not os.path.isdir(fs_path) else 0, st.st_mtime)

        depth = self.headers.get("Depth", "1")
        if depth != "0" and os.path.isdir(fs_path):
            for child in os.listdir(fs_path):
                child_path = os.path.join(fs_path, child)
                c_st = os.stat(child_path)
                child_href = req_path.rstrip("/") + "/" + urllib.parse.quote(child)
                if os.path.isdir(child_path):
                    child_href += "/"
                add_entry(child_href, os.path.isdir(child_path), c_st.st_size if not os.path.isdir(child_path) else 0, c_st.st_mtime)

        body = ('<?xml version="1.0" encoding="utf-8" ?>\n'
                '<D:multistatus xmlns:D="DAV:">\n' +
                "\n".join(xml_entries) +
                "\n</D:multistatus>\n").encode("utf-8")

        self.send_response(207, "Multi-Status")
        self.send_header("Content-Type", 'application/xml; charset="utf-8"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_MKCOL(self):
        fs_path = self.get_fs_path()
        if os.path.exists(fs_path):
            self.send_response(200) # Directory exists, treated as OK
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        try:
            os.makedirs(fs_path, exist_ok=True)
            self.send_response(201, "Created")
            self.send_header("Content-Length", "0")
            self.end_headers()
        except Exception as e:
            self.send_error(500, str(e))

    def do_PUT(self):
        fs_path = self.get_fs_path()
        length = int(self.headers.get("Content-Length", 0))
        os.makedirs(os.path.dirname(fs_path), exist_ok=True)
        try:
            with open(fs_path, "wb") as f:
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 65536))
                    if not chunk:
                        break
                    f.write(chunk)
                    remaining -= len(chunk)
            self.send_response(201, "Created")
            self.send_header("Content-Length", "0")
            self.end_headers()
        except Exception as e:
            self.send_error(500, str(e))

    def do_GET(self):
        fs_path = self.get_fs_path()
        if not os.path.exists(fs_path) or os.path.isdir(fs_path):
            self.send_error(404, "Not Found")
            return
        try:
            with open(fs_path, "rb") as f:
                content = f.read()
            self.send_response(200, "OK")
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            self.send_error(500, str(e))

    def do_DELETE(self):
        fs_path = self.get_fs_path()
        if not os.path.exists(fs_path):
            self.send_error(404, "Not Found")
            return
        try:
            if os.path.isdir(fs_path):
                shutil.rmtree(fs_path)
            else:
                os.remove(fs_path)
            self.send_response(204, "No Content")
            self.send_header("Content-Length", "0")
            self.end_headers()
        except Exception as e:
            self.send_error(500, str(e))


class MiniWebDAVServer:
    def __init__(self, host="127.0.0.1", port=0):
        self.root_dir = tempfile.mkdtemp(prefix="koreader_webdav_test_")
        self.server = HTTPServer((host, port), WebDAVRequestHandler)
        self.server.root_dir = self.root_dir
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        try:
            shutil.rmtree(self.root_dir)
        except Exception:
            pass


# -----------------------------------------------------------------------------
# 2. Zero-Dependency In-Process FTP Server
# -----------------------------------------------------------------------------
class FTPHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.root_dir = self.server.root_dir
        self.cwd = "/"
        self.pasv_sock = None
        self.pasv_conn = None

        self.wfile.write(b"220 KOReader Test FTP Server Ready\r\n")
        self.wfile.flush()

        while True:
            line = self.rfile.readline()
            if not line:
                break
            cmd_line = line.decode("utf-8", errors="ignore").strip()
            if not cmd_line:
                continue
            parts = cmd_line.split(" ", 1)
            cmd = parts[0].upper()
            arg = parts[1] if len(parts) > 1 else ""

            if cmd == "QUIT":
                self.wfile.write(b"221 Goodbye\r\n")
                self.wfile.flush()
                break
            elif cmd == "USER":
                self.wfile.write(b"331 User name okay, need password\r\n")
            elif cmd == "PASS":
                self.wfile.write(b"230 User logged in, proceed\r\n")
            elif cmd == "SYST":
                self.wfile.write(b"215 UNIX Type: L8\r\n")
            elif cmd == "FEAT":
                self.wfile.write(b"211-Features:\r\n UTF8\r\n211 End\r\n")
            elif cmd == "PWD":
                self.wfile.write(f'257 "{self.cwd}" is current directory\r\n'.encode("utf-8"))
            elif cmd == "TYPE":
                self.wfile.write(b"200 Type set to I\r\n")
            elif cmd == "CWD":
                new_cwd = os.path.normpath(os.path.join(self.cwd, arg)).replace("\\", "/")
                target = os.path.normpath(os.path.join(self.root_dir, new_cwd.lstrip("/")))
                os.makedirs(target, exist_ok=True)
                self.cwd = new_cwd
                self.wfile.write(b"250 Directory successfully changed\r\n")
            elif cmd == "MKD":
                target = os.path.normpath(os.path.join(self.root_dir, self.cwd.lstrip("/"), arg))
                os.makedirs(target, exist_ok=True)
                self.wfile.write(b"257 Directory created\r\n")
            elif cmd == "PASV":
                if self.pasv_sock:
                    self.pasv_sock.close()
                self.pasv_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.pasv_sock.bind(("127.0.0.1", 0))
                self.pasv_sock.listen(1)
                port = self.pasv_sock.getsockname()[1]
                p1, p2 = port // 256, port % 256
                self.wfile.write(f"227 Entering Passive Mode (127,0,0,1,{p1},{p2})\r\n".encode("utf-8"))
            elif cmd == "EPSV":
                if self.pasv_sock:
                    self.pasv_sock.close()
                self.pasv_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.pasv_sock.bind(("127.0.0.1", 0))
                self.pasv_sock.listen(1)
                port = self.pasv_sock.getsockname()[1]
                self.wfile.write(f"229 Entering Extended Passive Mode (|||{port}|)\r\n".encode("utf-8"))
            elif cmd in ("NLST", "LIST"):
                self.wfile.write(b"150 Opening data connection for directory list\r\n")
                self.wfile.flush()
                target_dir = os.path.normpath(os.path.join(self.root_dir, self.cwd.lstrip("/")))
                listing = ""
                if os.path.exists(target_dir):
                    for item in os.listdir(target_dir):
                        if cmd == "NLST":
                            listing += item + "\r\n"
                        else:
                            st = os.stat(os.path.join(target_dir, item))
                            mode = "drwxr-xr-x" if os.path.isdir(os.path.join(target_dir, item)) else "-rw-r--r--"
                            listing += f"{mode} 1 owner group {st.st_size} Jan 01 00:00 {item}\r\n"
                if self.pasv_sock:
                    conn, _ = self.pasv_sock.accept()
                    conn.sendall(listing.encode("utf-8"))
                    conn.close()
                    self.pasv_sock.close()
                    self.pasv_sock = None
                self.wfile.write(b"226 Directory send OK\r\n")
            elif cmd == "STOR":
                self.wfile.write(b"150 Ok to send data\r\n")
                self.wfile.flush()
                target_file = os.path.normpath(os.path.join(self.root_dir, self.cwd.lstrip("/"), arg))
                os.makedirs(os.path.dirname(target_file), exist_ok=True)
                if self.pasv_sock:
                    conn, _ = self.pasv_sock.accept()
                    with open(target_file, "wb") as f:
                        while True:
                            data = conn.recv(65536)
                            if not data:
                                break
                            f.write(data)
                    conn.close()
                    self.pasv_sock.close()
                    self.pasv_sock = None
                self.wfile.write(b"226 Transfer complete\r\n")
            elif cmd == "RETR":
                target_file = os.path.normpath(os.path.join(self.root_dir, self.cwd.lstrip("/"), arg))
                if not os.path.exists(target_file):
                    self.wfile.write(b"550 File not found\r\n")
                else:
                    self.wfile.write(b"150 Opening BINARY mode data connection\r\n")
                    self.wfile.flush()
                    if self.pasv_sock:
                        conn, _ = self.pasv_sock.accept()
                        with open(target_file, "rb") as f:
                            conn.sendall(f.read())
                        conn.close()
                        self.pasv_sock.close()
                        self.pasv_sock = None
                    self.wfile.write(b"226 Transfer complete\r\n")
            elif cmd == "DELE":
                target_file = os.path.normpath(os.path.join(self.root_dir, self.cwd.lstrip("/"), arg))
                if os.path.exists(target_file):
                    os.remove(target_file)
                    self.wfile.write(b"250 File deleted successfully\r\n")
                else:
                    self.wfile.write(b"550 File not found\r\n")
            else:
                self.wfile.write(b"502 Command not implemented\r\n")
            self.wfile.flush()

        if self.pasv_sock:
            self.pasv_sock.close()


class MiniFTPServer:
    def __init__(self, host="127.0.0.1", port=0):
        self.root_dir = tempfile.mkdtemp(prefix="koreader_ftp_test_")
        self.server = socketserver.ThreadingTCPServer((host, port), FTPHandler)
        self.server.root_dir = self.root_dir
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        try:
            shutil.rmtree(self.root_dir)
        except Exception:
            pass


# -----------------------------------------------------------------------------
# 3. Main Integration Test Runner
# -----------------------------------------------------------------------------
def main():
    if sys.platform == "win32":
        # Forward execution to WSL so ephemeral test servers and LuaJIT share the identical 127.0.0.1 network namespace
        wsl_path = "/mnt/c/Users/Jimmy/Documents/backup/backup.koplugin/tools/test_live_servers.py"
        res = subprocess.run(["wsl", "python3", wsl_path])
        return res.returncode

    print("=" * 60)
    print("      KOReader Backup Live Cloud Integration Test Runner")
    print("=" * 60)

    print("\n[1/3] Spinning up ephemeral test servers on 127.0.0.1...")
    webdav_server = MiniWebDAVServer()
    webdav_server.start()
    print(f"  ✓ WebDAV Server listening on: http://127.0.0.1:{webdav_server.port}")

    ftp_server = MiniFTPServer()
    ftp_server.start()
    print(f"  ✓ FTP Server listening on:    127.0.0.1:{ftp_server.port}")

    # Give servers a fraction of a second to bind
    time.sleep(0.2)

    print("\n[2/3] Executing Live Lua Driver Tests via LuaJIT (WSL)...")
    env = os.environ.copy()
    env["TEST_WEBDAV_PORT"] = str(webdav_server.port)
    env["TEST_FTP_PORT"] = str(ftp_server.port)

    # Command to run tests/live_cloud_test.lua in WSL
    repo_dir_wsl = "/mnt/c/Users/Jimmy/Documents/backup/backup.koplugin"
    cmd = (
        f"cd {repo_dir_wsl} && "
        f"TEST_WEBDAV_PORT={webdav_server.port} TEST_FTP_PORT={ftp_server.port} "
        f"LD_LIBRARY_PATH=/home/jimmy/squashfs-root/usr/lib/koreader/libs:/home/jimmy/squashfs-root/usr/lib/koreader "
        f"/home/jimmy/squashfs-root/usr/lib/koreader/luajit tests/live_cloud_test.lua"
    )

    success = False
    try:
        if sys.platform == "win32":
            res = subprocess.run(["wsl", "bash", "-c", cmd], capture_output=True, text=True, timeout=30)
        else:
            res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=30)
        print(res.stdout)
        if res.stderr:
            print(res.stderr, file=sys.stderr)
        success = (res.returncode == 0)
    except Exception as e:
        print(f"Failed to execute live test: {e}")
        success = False

    print("\n[3/3] Shutting down ephemeral test servers...")
    webdav_server.stop()
    ftp_server.stop()
    print("  ✓ Servers stopped and temporary storage cleaned up.")

    print("\n" + "=" * 60)
    if success:
        print("  ✅ ALL LIVE INTEGRATION TESTS PASSED END-TO-END!")
        print("=" * 60)
        return 0
    else:
        print("  ❌ LIVE INTEGRATION TESTS ENCOUNTERED ERRORS.")
        print("=" * 60)
        return 1

if __name__ == "__main__":
    sys.exit(main())
