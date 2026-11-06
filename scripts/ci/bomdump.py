import struct, sys
d = open(sys.argv[1], 'rb').read()
only = sys.argv[2] if len(sys.argv) > 2 else None
magic, ver, nblocks, ioff, ilen, voff, vlen = struct.unpack('>8sIIIIII', d[:32])
cnt = struct.unpack('>I', d[ioff:ioff+4])[0]
blocks = [struct.unpack('>II', d[ioff+4+8*i: ioff+12+8*i]) for i in range(cnt)]
def blk(i):
    o, l = blocks[i]; return d[o:o+l]
n = struct.unpack('>I', d[voff:voff+4])[0]; p = voff + 4
vars_ = {}
for _ in range(n):
    idx, ln = struct.unpack('>IB', d[p:p+5]); name = d[p+5:p+5+ln].decode(); p += 5 + ln; vars_[name] = idx
print('blocks', cnt, 'vars', {k: (v, blocks[v][1]) for k, v in vars_.items()})
def node(i):
    b = blk(i)
    isleaf, count, fwd, bwd = struct.unpack('>HHII', b[:12])
    ents = [struct.unpack('>II', b[12+8*j:20+8*j]) for j in range(count)]
    return isleaf, count, fwd, bwd, ents, len(b)
for name, idx in vars_.items():
    if only and name != only: continue
    b = blk(idx)
    if b[:4] != b'tree': continue
    _, v, child, bs, pc, ip = struct.unpack('>4sIIIIB', b[:21])
    print(f'== {name}: version {v} root {child} blockSize {bs} pathCount {pc} inlineKeys {ip} headerLen {len(b)}')
    level = [child]; depth = 0
    while level and depth < 6:
        nxt = []; summary = []
        for nid in level:
            isleaf, count, fwd, bwd, ents, ln = node(nid)
            summary.append((nid, isleaf, count, fwd, bwd, ln))
            if not isleaf: nxt += [e[0] for e in ents]
        print(f' depth {depth}: {len(level)} node(s); first 4: {summary[:4]}')
        if depth == 0 or not nxt:
            isleaf, count, fwd, bwd, ents, ln = node(level[0])
            print('  first node entries (index0,index1):', ents[:6], '...', ents[-2:])
            if not isleaf and ents:
                print('  first key blocks lens:', [len(blk(e[1])) if e[1] < cnt and e[1] else None for e in ents[:3]])
        level = nxt; depth += 1

if only is None or only == 'RENDITIONS':
    b = blk(vars_['RENDITIONS']); child = struct.unpack('>I', b[8:12])[0]
    isleaf, count, fwd, bwd, ents, ln = node(child)
    print('RAW root', child, isleaf, count, fwd, bwd, ln)
    cur = ents[0][0]
    seen = 0
    while cur and seen < 12:
        nb = blk(cur)
        il, c, f, bk, es, l = node(cur)
        tail = nb[12 + 8*c: 12 + 8*c + 48]
        print(f'RAW leaf {cur}: isLeaf {il} count {c} fwd {f} bwd {bk} blocklen {l} tailhex {tail.hex()}')
        print('    first entries', es[:3], 'last', es[-2:], ' value-block lens', [blocks[e[0]][1] for e in es[:3]], [blocks[e[0]][1] for e in es[-3:]], 'key-block lens', [blocks[e[1]][1] for e in es[-2:]])
        cur = f; seen += 1

if only is None or only == 'RENDITIONS':
    import collections
    b = blk(vars_['RENDITIONS']); child = struct.unpack('>I', b[8:12])[0]
    _, _, _, _, ents, _ = node(child)
    cur = ents[0][0]; li = 0
    while cur:
        il, c, f, bk, es, l = node(cur)
        bad = collections.Counter(); pix = collections.Counter(); layout = collections.Counter()
        for (v, k) in es:
            val = blk(v)
            magic = val[:4]
            bad[magic] += 1
            if magic == b'CTSI':
                pix[val[24:28]] += 1
                layout[struct.unpack('<HH', val[0x24+0x8*0:0x24+4])] += 0
        print(f'CSI leaf#{li} block {cur}: magics {dict(bad)} pixfmt {dict(pix)}')
        if li == 0 or f == 0:
            for (v, k) in es[:2] + es[-2:]:
                val = blk(v); kk = blk(k)
                print('   key', kk.hex(), 'csi', val[:64].hex(), 'len', len(val))
        cur = f; li += 1

if only is None or only == 'RENDITIONS':
    kf = blk(vars_['KEYFORMAT'])
    cnt_attr = struct.unpack('<I', kf[8:12])[0]
    print('KEYFORMAT attrs', struct.unpack('<%dI' % cnt_attr, kf[12:12+4*cnt_attr]), 'magic', kf[:4])
    b = blk(vars_['RENDITIONS']); child = struct.unpack('>I', b[8:12])[0]
    _, _, _, _, ents, _ = node(child)
    cur = ents[0][0]; keys = []
    while cur:
        il, c, f, bk, es, l = node(cur)
        keys += [blk(k) for (v, k) in es]
        cur = f
    def u16(k): return struct.unpack('<%dH' % (len(k)//2), k)
    for label, fn in (('bytewise', lambda k: k), ('LE u16 tuple', u16)):
        bad = [i for i in range(1, len(keys)) if fn(keys[i-1]) > fn(keys[i])]
        print(f'order check {label}: {len(keys)} keys, {len(bad)} out of order; first violations {bad[:5]}')
    print('first/last keys as u16:', u16(keys[0]), u16(keys[-1]))
