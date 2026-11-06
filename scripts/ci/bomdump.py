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
