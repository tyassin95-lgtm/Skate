"""Minimal binary FBX (7x00) reader - enough to pull static mesh geometry out."""
import struct, zlib

class Node:
    def __init__(self, name):
        self.name = name; self.props = []; self.children = []
    def find(self, name):
        for c in self.children:
            if c.name == name: return c
        return None
    def find_all(self, name):
        return [c for c in self.children if c.name == name]
    def __repr__(self):
        return "<%s props=%d kids=%d>" % (self.name, len(self.props), len(self.children))

def _read_prop(f):
    t = f.read(1).decode('ascii')
    if t == 'Y': return struct.unpack('<h', f.read(2))[0]
    if t == 'C': return struct.unpack('<?', f.read(1))[0]
    if t == 'I': return struct.unpack('<i', f.read(4))[0]
    if t == 'F': return struct.unpack('<f', f.read(4))[0]
    if t == 'D': return struct.unpack('<d', f.read(8))[0]
    if t == 'L': return struct.unpack('<q', f.read(8))[0]
    if t in 'fdlib':
        n, enc, clen = struct.unpack('<III', f.read(12))
        data = f.read(clen)
        if enc == 1: data = zlib.decompress(data)
        fmt = {'f': 'f', 'd': 'd', 'l': 'q', 'i': 'i', 'b': 'b'}[t]
        return list(struct.unpack('<%d%s' % (n, fmt), data))
    if t in 'SR':
        n = struct.unpack('<I', f.read(4))[0]
        raw = f.read(n)
        return raw.decode('utf-8', 'replace') if t == 'S' else raw
    raise ValueError('unknown FBX property type %r' % t)

def _read_node(f, ver):
    wide = ver >= 7500
    hdr = struct.calcsize('<QQQB' if wide else '<IIIB')
    start = f.tell()
    if wide: end, nprops, plen, nlen = struct.unpack('<QQQB', f.read(hdr))
    else:    end, nprops, plen, nlen = struct.unpack('<IIIB', f.read(hdr))
    if end == 0:  # null record terminates a list
        return None
    node = Node(f.read(nlen).decode('utf-8', 'replace'))
    for _ in range(nprops):
        node.props.append(_read_prop(f))
    # nested list, if any bytes remain before EndOffset
    while f.tell() < end - (25 if wide else 13):
        c = _read_node(f, ver)
        if c is None: break
        node.children.append(c)
    f.seek(end)
    return node

def parse(path):
    with open(path, 'rb') as f:
        magic = f.read(21)
        if not magic.startswith(b'Kaydara FBX Binary'):
            raise ValueError('not a binary FBX')
        f.read(2)
        ver = struct.unpack('<I', f.read(4))[0]
        root = Node('__root__')
        while True:
            n = _read_node(f, ver)
            if n is None: break
            root.children.append(n)
        return root, ver
