"""Dumps a compiled .nib (NIBArchive) as readable text: objects, their class and key/value pairs."""
import struct, sys

def varint(d, p):
    v, shift = 0, 0
    while True:
        b = d[p]; p += 1
        v |= (b & 0x7f) << shift
        if b & 0x80: return v, p
        shift += 7

def parse(path):
    d = open(path, 'rb').read()
    assert d[:10] == b'NIBArchive', d[:10]
    ver, minor, oc, oo, kc, ko, vc, vo, cc, co = struct.unpack('<10I', d[10:50])
    p = oo; objs = []
    for _ in range(oc):
        c, p = varint(d, p); s, p = varint(d, p); n, p = varint(d, p); objs.append((c, s, n))
    p = ko; keys = []
    for _ in range(kc):
        l, p = varint(d, p); keys.append(d[p:p+l].decode('utf8', 'replace')); p += l
    p = vo; vals = []
    for _ in range(vc):
        k, p = varint(d, p); t = d[p]; p += 1
        if t == 0: v = struct.unpack('<b', d[p:p+1])[0]; p += 1
        elif t == 1: v = struct.unpack('<h', d[p:p+2])[0]; p += 2
        elif t == 2: v = struct.unpack('<i', d[p:p+4])[0]; p += 4
        elif t == 3: v = struct.unpack('<q', d[p:p+8])[0]; p += 8
        elif t == 4: v = True
        elif t == 5: v = False
        elif t == 6: v = struct.unpack('<f', d[p:p+4])[0]; p += 4
        elif t == 7: v = struct.unpack('<d', d[p:p+8])[0]; p += 8
        elif t == 8:
            l, p = varint(d, p); v = bytes(d[p:p+l]); p += l
        elif t == 9: v = None
        elif t == 10: v = ('obj', struct.unpack('<I', d[p:p+4])[0]); p += 4
        else: raise Exception('type %d at %d' % (t, p))
        vals.append((k, t, v))
    p = co; classes = []
    for _ in range(cc):
        l, p = varint(d, p); e, p = varint(d, p)
        ex = list(struct.unpack('<%dI' % e, d[p:p+4*e])); p += 4*e
        classes.append((d[p:p+l-1].decode(), ex)); p += l
    return dict(ver=(ver, minor), objs=objs, keys=keys, vals=vals, classes=classes, size=len(d), end=p)

def dump(path, out=sys.stdout):
    n = parse(path)
    out.write('# %s  version %s  size %d (parsed to %d)\n' % (path, n['ver'], n['size'], n['end']))
    for i, (c, s, cnt) in enumerate(n['objs']):
        out.write('[%d] %s %s\n' % (i, n['classes'][c][0], n['classes'][c][1] or ''))
        for k, t, v in n['vals'][s:s+cnt]:
            if isinstance(v, bytes): v = 'data(%d) %s' % (len(v), v[:40].hex())
            out.write('    %s (t%d) = %s\n' % (n['keys'][k], t, v))

if __name__ == '__main__':
    dump(sys.argv[1])
