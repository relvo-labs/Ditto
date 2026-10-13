# Runs inside ditto-confine. Each line is "<check> <result>"; the Rust test
# decides which results are acceptable. Never prints file contents.
import errno, os, signal, socket, sys

home, allowed_unix, denied_unix, abstract_name, tcp_ok, tcp_denied, bind_ok, supervisor = sys.argv[1:9]
tcp_ok, tcp_denied, bind_ok, supervisor = int(tcp_ok), int(tcp_denied), int(bind_ok), int(supervisor)

def report(check, action):
    try:
        action()
        print(check, "ok", flush=True)
    except OSError as error:
        print(check, errno.errorcode.get(error.errno, str(error.errno)), flush=True)

def write_inside():
    with open(os.path.join(home, "inside"), "w") as f:
        f.write("x")

def write_outside():
    with open("/tmp/ditto-confine-escape", "w") as f:
        f.write("x")

def unix_connect(path):
    def run():
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(path)
        s.sendall(b"ping")
        if s.recv(4) != b"pong":
            raise OSError(errno.EPROTO, "bad reply")
        s.close()
    return run

def abstract_connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect("\0" + abstract_name)

def family(fam, kind):
    return lambda: socket.socket(fam, kind).close()

def tcp(port, blocking=True):
    def run():
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if blocking:
            s.connect(("127.0.0.1", port))
        else:
            s.setblocking(False)
            code = s.connect_ex(("127.0.0.1", port))
            if code not in (0, errno.EINPROGRESS):
                raise OSError(code, "connect")
            s.setblocking(True)
            s.settimeout(5)
            s.send(b"x")
        s.close()
    return run

def bind(port):
    def run():
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", port))
        s.close()
    return run

def inet_socket_unix_address():
    # Family mismatch: the broker checks the socket object, not the bytes.
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    path = denied_unix.encode()
    address = (ctypes.c_ushort(socket.AF_UNIX).value).to_bytes(2, sys.byteorder) + path + b"\0"
    buffer = ctypes.create_string_buffer(address, len(address))
    if libc.connect(s.fileno(), buffer, len(address)) != 0:
        raise OSError(ctypes.get_errno(), "connect")

def unix_socket_inet_address():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    address = socket.AF_INET.to_bytes(2, sys.byteorder) + tcp_ok.to_bytes(2, "big") + bytes([127, 0, 0, 1]) + bytes(8)
    buffer = ctypes.create_string_buffer(address, len(address))
    if libc.connect(s.fileno(), buffer, len(address)) != 0:
        raise OSError(ctypes.get_errno(), "connect")

report("read_home", lambda: os.listdir("/home"))
report("write_inside", write_inside)
report("write_outside", write_outside)
report("unix_allowed", unix_connect(allowed_unix))
report("unix_denied", unix_connect(denied_unix))
report("unix_abstract", abstract_connect)
report("socket_netlink", family(socket.AF_NETLINK, socket.SOCK_RAW))
report("socket_unix_dgram", family(socket.AF_UNIX, socket.SOCK_DGRAM))
report("socket_packet", family(socket.AF_PACKET, socket.SOCK_RAW))
report("tcp_allowed", tcp(tcp_ok))
report("tcp_allowed_nonblocking", tcp(tcp_ok, blocking=False))
report("tcp_denied", tcp(tcp_denied))
report("bind_allowed", bind(bind_ok))
report("bind_denied", bind(tcp_denied))
report("inet_socket_unix_address", inet_socket_unix_address)
report("unix_socket_inet_address", unix_socket_inet_address)
report("signal_supervisor", lambda: os.kill(supervisor, 0))
