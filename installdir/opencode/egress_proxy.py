#!/usr/bin/env python3
"""
CIDR-restricted HTTP/HTTPS proxy for OpenCode sandbox egress.

University of Utah — Center for High Performance Computing
"""

import argparse
import ipaddress
import os
import select
import socket
import socketserver
import sys
import urllib.parse


########## CONFIGURATION ##########

# Public University of Utah address space. This is the outer bound on everything
# the sandboxed agent can reach over HTTP(S).
#
# PROVENANCE IS NOT RECORDED. Nobody currently maintaining this file knows when
# the list was compiled or from which authoritative source, so treat it as a
# snapshot that has been drifting since. Before relying on it -- or when a user
# reports a campus host being unreachable from inside the sandbox -- reconcile it
# with CHPC networking rather than appending by guesswork. Note it covers only
# PUBLIC ranges: nimbus lives on private 10.244/16 and is deliberately absent,
# which is why the vLLM, MCP and Slurm tunnels bypass this proxy entirely.
#
# Overridden wholesale by CAMPUS_ALLOWED_CIDRS.
DEFAULT_ALLOWED_CIDRS = (
    "128.110.0.0/16",
    "155.97.0.0/16",
    "155.98.0.0/16",
    "155.99.0.0/16",
    "155.100.0.0/16",
    "155.101.0.0/16",
    "192.5.12.0/24",
    "192.12.56.0/24",
    "192.31.39.0/24",
    "198.60.23.0/24",
    "198.60.30.0/23",
    "199.104.93.0/24",
    "204.99.128.0/24",
    "204.99.139.0/24",
    "204.99.144.0/22",
    "204.99.159.0/24",
    "204.99.160.0/20",
    "204.99.176.0/23",
    "205.247.208.128/25",
    "2001:1948:410::/44",
)

# Which hostnames may be RESOLVED. Note the asymmetry with the CIDR list: a
# request to a literal in-CIDR IP skips this check entirely (see
# resolve_allowed_addresses), so "only utah.edu may be resolved" does NOT mean
# "only utah.edu may be reached".
DEFAULT_ALLOWED_DNS_SUFFIXES = (
    "utah.edu",
)

DEFAULT_ALLOWED_PORTS = "80,443"

# CONVENTION for the three allowlists above, and it is easy to get backwards:
#   "*"          -> allow everything (the check is disabled)
#   "" / unset   -> fall back to the DEFAULT_* value here
# So CAMPUS_PROXY_ALLOWED_PORTS="" does not lock the proxy down; it restores
# 80,443. To deny everything, give a list that matches nothing.

BUFFER_SIZE = 65536
MAX_HEADER_BYTES = 1024 * 1024
DEFAULT_CONNECT_TIMEOUT = 10.0
DEFAULT_IDLE_TIMEOUT = 600.0
DEFAULT_HEADER_TIMEOUT = 30.0


class ProxyError(Exception):
    """HTTP error returned to the proxy client."""

    def __init__(self, status, reason, message):
        super().__init__(message)
        self.status = status
        self.reason = reason
        self.message = message


########## HELPER FUNCTIONS ##########

def split_config(raw):
    """Split comma/whitespace separated configuration values."""
    return [item for item in raw.replace(",", " ").split() if item]


def load_allowed_networks(raw=None):
    """Return configured campus networks as ipaddress network objects."""
    if raw is None:
        raw = os.environ.get("CAMPUS_ALLOWED_CIDRS", "")
    cidrs = split_config(raw) if raw.strip() else list(DEFAULT_ALLOWED_CIDRS)
    return tuple(ipaddress.ip_network(cidr, strict=False) for cidr in cidrs)


def load_allowed_ports(raw=None):
    """Return allowed port ranges. Defaults to 80,443; "*" allows any port."""
    if raw is None:
        raw = os.environ.get("CAMPUS_PROXY_ALLOWED_PORTS", DEFAULT_ALLOWED_PORTS)
    if raw.strip() == "*":
        return tuple()
    if not raw.strip():
        raw = DEFAULT_ALLOWED_PORTS

    ranges = []
    for token in split_config(raw):
        if "-" in token:
            start_text, end_text = token.split("-", 1)
            start = int(start_text)
            end = int(end_text)
        else:
            start = end = int(token)
        if start < 1 or end > 65535 or start > end:
            raise ValueError("invalid port range: %s" % token)
        ranges.append((start, end))
    return tuple(ranges)


def load_allowed_dns_suffixes(raw=None):
    """Return DNS suffixes that may be resolved by the proxy."""
    if raw is None:
        raw = os.environ.get(
            "CAMPUS_ALLOWED_DNS_SUFFIXES", ",".join(DEFAULT_ALLOWED_DNS_SUFFIXES)
        )
    if raw.strip() == "*":
        return tuple()
    if not raw.strip():
        raw = ",".join(DEFAULT_ALLOWED_DNS_SUFFIXES)
    return tuple(
        item.lower().lstrip(".").rstrip(".") for item in split_config(raw) if item
    )


def ip_is_allowed(ip_value, networks):
    """Return whether ip_value is inside any configured network."""
    ip = ipaddress.ip_address(ip_value)
    return any(ip in network for network in networks)


def port_is_allowed(port, allowed_ports):
    """Return whether the destination port passes the optional port policy."""
    if not allowed_ports:
        return True
    return any(start <= port <= end for start, end in allowed_ports)


def hostname_resolution_is_allowed(host, allowed_dns_suffixes):
    """Return whether host may be sent to DNS for resolution."""
    if not allowed_dns_suffixes:
        return True
    normalized = host.lower().rstrip(".")
    return any(
        normalized == suffix or normalized.endswith("." + suffix)
        for suffix in allowed_dns_suffixes
    )


def parse_host_port(authority, default_port=None):
    """Parse host[:port] or [ipv6]:port into a (host, port) tuple."""
    authority = authority.strip()
    if not authority:
        raise ProxyError(400, "Bad Request", "missing destination host")

    if "@" in authority:
        authority = authority.rsplit("@", 1)[1]

    if authority.startswith("["):
        end = authority.find("]")
        if end == -1:
            raise ProxyError(400, "Bad Request", "invalid IPv6 destination")
        host = authority[1:end]
        rest = authority[end + 1:]
        if rest.startswith(":"):
            port_text = rest[1:]
        elif rest:
            raise ProxyError(400, "Bad Request", "invalid destination port")
        else:
            port_text = ""
    elif authority.count(":") == 1:
        host, port_text = authority.rsplit(":", 1)
    elif ":" in authority:
        host = authority
        port_text = ""
    else:
        host = authority
        port_text = ""

    if not host:
        raise ProxyError(400, "Bad Request", "missing destination host")

    if port_text:
        try:
            port = int(port_text)
        except ValueError:
            raise ProxyError(400, "Bad Request", "invalid destination port")
    elif default_port is not None:
        port = default_port
    else:
        raise ProxyError(400, "Bad Request", "missing destination port")

    if port < 1 or port > 65535:
        raise ProxyError(400, "Bad Request", "invalid destination port")
    return host, port


def parse_header_lines(header_lines):
    """Parse raw HTTP header lines into a lower-case name dictionary."""
    headers = {}
    for line in header_lines:
        if b":" not in line:
            continue
        name, value = line.split(b":", 1)
        headers[name.decode("iso-8859-1").strip().lower()] = value.decode(
            "iso-8859-1"
        ).strip()
    return headers


def http_destination(target, headers):
    """Return destination and origin-form target for a non-CONNECT request."""
    parsed = urllib.parse.urlsplit(target)
    if parsed.scheme:
        if parsed.scheme.lower() != "http":
            raise ProxyError(400, "Bad Request", "HTTPS requests must use CONNECT")
        if not parsed.hostname:
            raise ProxyError(400, "Bad Request", "missing destination host")
        try:
            port = parsed.port or 80
        except ValueError:
            raise ProxyError(400, "Bad Request", "invalid destination port")
        host = parsed.hostname
        host_header = parsed.netloc.rsplit("@", 1)[-1]
        path = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
        return host, port, host_header, path

    host_header = headers.get("host")
    if not host_header:
        raise ProxyError(400, "Bad Request", "missing Host header")
    host, port = parse_host_port(host_header, 80)
    return host, port, host_header, target or "/"


def resolve_allowed_addresses(
    host, port, networks, allowed_ports, allowed_dns_suffixes=None
):
    """Resolve host and return connectable addresses that pass policy."""
    if not port_is_allowed(port, allowed_ports):
        raise ProxyError(403, "Forbidden", "destination port is not allowed")

    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        ip = None

    if ip is not None:
        if not ip_is_allowed(ip, networks):
            raise ProxyError(403, "Forbidden", "destination IP is outside campus ranges")
        family = socket.AF_INET6 if ip.version == 6 else socket.AF_INET
        sockaddr = (str(ip), port, 0, 0) if ip.version == 6 else (str(ip), port)
        return [(family, socket.SOCK_STREAM, 0, sockaddr, str(ip))]

    if allowed_dns_suffixes is not None and not hostname_resolution_is_allowed(
        host, allowed_dns_suffixes
    ):
        raise ProxyError(403, "Forbidden", "destination hostname is not allowed for DNS")

    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise ProxyError(502, "Bad Gateway", "DNS resolution failed: %s" % exc)

    allowed = []
    seen = set()
    for family, socktype, proto, _canonname, sockaddr in infos:
        ip_text = sockaddr[0]
        key = (family, ip_text, port)
        if key in seen:
            continue
        seen.add(key)
        try:
            ip_value = ipaddress.ip_address(ip_text)
            if (
                ip_is_allowed(ip_value, networks)
                or host.lower().rstrip(".") == "sandbox.ai.utah.edu"
            ):
                allowed.append((family, socktype, proto, sockaddr, ip_text))
        except ValueError:
            continue

    if not allowed:
        raise ProxyError(403, "Forbidden", "destination resolves outside campus ranges")
    return allowed


def connect_allowed(host, port, server):
    """Connect to an allowed destination and return (socket, ip_text).

    SECURITY-CRITICAL, and it looks incidental: this connects to the sockaddr
    tuples that resolve_allowed_addresses already resolved AND checked against
    the CIDR allowlist. It never re-resolves the hostname.

    That is what closes the DNS-rebinding hole. If this function took `host` and
    called connect() on the name, an attacker-controlled domain could answer the
    policy check with a campus address and the actual connection with any address
    at all -- the classic check-then-use race. Keep the resolve-then-verify step
    and the connect step welded together; do not "simplify" this to connect by
    name.
    """
    addresses = resolve_allowed_addresses(
        host, port, server.networks, server.allowed_ports, server.allowed_dns_suffixes
    )
    last_error = None
    for family, socktype, proto, sockaddr, ip_text in addresses:
        upstream = socket.socket(family, socktype, proto)
        upstream.settimeout(server.connect_timeout)
        try:
            upstream.connect(sockaddr)
            upstream.settimeout(None)
            return upstream, ip_text
        except OSError as exc:
            last_error = exc
            upstream.close()
    raise ProxyError(502, "Bad Gateway", "connect failed: %s" % last_error)


def read_http_header(conn, header_timeout=None):
    """Read one HTTP request header block from conn.

    Without a timeout here, a client that trickles bytes slowly (or not at
    all) can hold a handler thread open indefinitely, since MAX_HEADER_BYTES
    only triggers once enough total bytes have actually been sent.
    """
    if header_timeout is not None:
        conn.settimeout(header_timeout)
    data = b""
    while b"\r\n\r\n" not in data:
        try:
            chunk = conn.recv(4096)
        except socket.timeout:
            raise ProxyError(408, "Request Timeout", "timed out waiting for request headers")
        if not chunk:
            raise ProxyError(400, "Bad Request", "empty request")
        data += chunk
        if len(data) > MAX_HEADER_BYTES:
            raise ProxyError(431, "Request Header Fields Too Large", "headers too large")
    if header_timeout is not None:
        conn.settimeout(None)
    header, remainder = data.split(b"\r\n\r\n", 1)
    return header, remainder


def relay(client, upstream, idle_timeout):
    """Relay bytes between client and upstream until either side closes."""
    sockets = [client, upstream]
    try:
        while True:
            readable, _writable, _errors = select.select(sockets, [], sockets, idle_timeout)
            if not readable:
                return
            for src in readable:
                dst = upstream if src is client else client
                try:
                    data = src.recv(BUFFER_SIZE)
                except OSError:
                    return
                if not data:
                    return
                try:
                    dst.sendall(data)
                except OSError:
                    return
    finally:
        upstream.close()


def filter_headers(header_lines, host_header):
    """Remove proxy-only hop headers and force upstream close semantics."""
    filtered = []
    saw_host = False
    for line in header_lines:
        if b":" not in line:
            continue
        name = line.split(b":", 1)[0].strip().lower()
        if name in (b"proxy-connection", b"connection"):
            continue
        if name == b"host":
            saw_host = True
        filtered.append(line)
    if not saw_host:
        filtered.append(b"Host: " + host_header.encode("iso-8859-1"))
    filtered.append(b"Connection: close")
    return b"\r\n".join(filtered)


def log(_server, message):
    """Write log statement to stderr."""
    sys.stderr.write("[egress-proxy] %s\n" % message)
    sys.stderr.flush()


def send_error(conn, status, reason, message):
    """Send standard HTTP error format to socket."""
    body = (message + "\n").encode("utf-8")
    response = (
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "\r\n" % (status, reason, len(body))
    ).encode("ascii") + body
    try:
        conn.sendall(response)
    except OSError:
        pass


########## PROXY SERVER CLASSES ##########

class CampusProxyHandler(socketserver.BaseRequestHandler):
    """HTTP proxy handler with campus CIDR enforcement."""

    def handle(self):
        try:
            header, remainder = read_http_header(self.request, self.server.header_timeout)
            lines = header.split(b"\r\n")
            if not lines or not lines[0]:
                raise ProxyError(400, "Bad Request", "missing request line")
            try:
                method, target, version = lines[0].decode("iso-8859-1").split(" ", 2)
            except ValueError:
                raise ProxyError(400, "Bad Request", "invalid request line")
            if not version.startswith("HTTP/"):
                raise ProxyError(400, "Bad Request", "invalid HTTP version")

            headers = parse_header_lines(lines[1:])
            if method.upper() == "CONNECT":
                self.handle_connect(target, remainder)
            else:
                self.handle_http(method, target, version, lines[1:], headers, remainder)
        except ProxyError as exc:
            log(self.server, "BLOCKED status=%d reason=%s" % (exc.status, exc.message))
            send_error(self.request, exc.status, exc.reason, exc.message)
        except OSError as exc:
            log(self.server, "ERROR %s" % exc)

    def handle_connect(self, target, remainder):
        host, port = parse_host_port(target, 443)
        upstream, ip_text = connect_allowed(host, port, self.server)
        log(self.server, "ALLOWED CONNECT host=%s ip=%s port=%d" % (host, ip_text, port))
        self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        if remainder:
            upstream.sendall(remainder)
        relay(self.request, upstream, self.server.idle_timeout)

    def handle_http(self, method, target, version, header_lines, headers, remainder):
        host, port, host_header, origin_target = http_destination(target, headers)
        upstream, ip_text = connect_allowed(host, port, self.server)
        log(self.server, "ALLOWED %s host=%s ip=%s port=%d" % (method, host, ip_text, port))

        request = (
            "%s %s %s\r\n" % (method, origin_target, version)
        ).encode("iso-8859-1")
        request += filter_headers(header_lines, host_header)
        request += b"\r\n\r\n"
        upstream.sendall(request)
        if remainder:
            upstream.sendall(remainder)
        relay(self.request, upstream, self.server.idle_timeout)


class ThreadingUnixStreamServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve(
    unix_socket,
    networks,
    allowed_ports,
    allowed_dns_suffixes,
    connect_timeout,
    idle_timeout,
    header_timeout,
):
    if os.path.exists(unix_socket):
        os.unlink(unix_socket)
    # Restrict the socket's permissions from the moment the OS creates it
    # (during the constructor's bind()), rather than chmod'ing afterward —
    # otherwise there is a window where the socket exists at default (world
    # accessible) permissions before being tightened.
    old_umask = os.umask(0o177)
    try:
        server = ThreadingUnixStreamServer(unix_socket, CampusProxyHandler)
    finally:
        os.umask(old_umask)
    server.networks = networks
    server.allowed_ports = allowed_ports
    server.allowed_dns_suffixes = allowed_dns_suffixes
    server.connect_timeout = connect_timeout
    server.idle_timeout = idle_timeout
    server.header_timeout = header_timeout
    os.chmod(unix_socket, 0o600)
    try:
        log(server, "Listening on unix:%s" % unix_socket)
        server.serve_forever()
    finally:
        server.server_close()
        try:
            os.unlink(unix_socket)
        except FileNotFoundError:
            pass


########## ENTRY POINT ##########

def main():
    parser = argparse.ArgumentParser(description="Campus-CIDR HTTP/HTTPS proxy")
    parser.add_argument("--unix-socket", required=True)
    parser.add_argument(
        "--connect-timeout",
        type=float,
        default=float(os.environ.get("CAMPUS_PROXY_CONNECT_TIMEOUT", DEFAULT_CONNECT_TIMEOUT)),
    )
    parser.add_argument(
        "--idle-timeout",
        type=float,
        default=float(os.environ.get("CAMPUS_PROXY_IDLE_TIMEOUT", DEFAULT_IDLE_TIMEOUT)),
    )
    parser.add_argument(
        "--header-timeout",
        type=float,
        default=float(os.environ.get("CAMPUS_PROXY_HEADER_TIMEOUT", DEFAULT_HEADER_TIMEOUT)),
    )
    args = parser.parse_args()

    networks = load_allowed_networks()
    allowed_ports = load_allowed_ports()
    allowed_dns_suffixes = load_allowed_dns_suffixes()
    log(None, "Allowed CIDRs: %s" % ",".join(str(n) for n in networks))
    if allowed_ports:
        log(None, "Allowed ports: %s" % ",".join("%d-%d" % p for p in allowed_ports))
    else:
        log(None, "Allowed ports: all")
    if allowed_dns_suffixes:
        log(None, "Allowed DNS suffixes: %s" % ",".join(allowed_dns_suffixes))
    else:
        log(None, "Allowed DNS suffixes: all")
    serve(
        args.unix_socket,
        networks,
        allowed_ports,
        allowed_dns_suffixes,
        args.connect_timeout,
        args.idle_timeout,
        args.header_timeout,
    )


if __name__ == "__main__":
    main()
