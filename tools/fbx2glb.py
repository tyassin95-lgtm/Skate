"""Convert the static mesh of a binary FBX into a normalised, game-ready GLB.

The source skateboard is authored at Blender/FBX scale (~cm) with a non-uniform
object scale baked on the Model node. We bake T*R*S into the vertices and then
uniformly rescale so the deck is `target_length` metres long, centred on the
origin with the deck's top surface at y=0 -- which is what the game expects.
"""
import sys, os, json, struct, math

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fbx


def euler_xyz_matrix(rx, ry, rz):
    rx, ry, rz = math.radians(rx), math.radians(ry), math.radians(rz)
    cx, sx = math.cos(rx), math.sin(rx)
    cy, sy = math.cos(ry), math.sin(ry)
    cz, sz = math.cos(rz), math.sin(rz)
    # FBX default rotation order is XYZ, applied as R = Rz * Ry * Rx
    return [
        [cy * cz, cz * sx * sy - cx * sz, cx * cz * sy + sx * sz],
        [cy * sz, cx * cz + sx * sy * sz, -cz * sx + cx * sy * sz],
        [-sy,     cy * sx,                cx * cy],
    ]


def prop70(node, name, default):
    p = node.find('Properties70')
    if p is None:
        return default
    for c in p.children:
        if c.props and c.props[0] == name:
            return c.props[4:]
    return default


def convert(fbx_path, png_path, out_path, target_length=0.80):
    root, ver = fbx.parse(fbx_path)
    objs = root.find('Objects')

    geo = next(o for o in objs.children if o.name == 'Geometry')
    model = next(o for o in objs.children
                 if o.name == 'Model' and str(o.props[1]).startswith('Cube'))

    verts = geo.find('Vertices').props[0]
    poly = geo.find('PolygonVertexIndex').props[0]
    nrm_l = geo.find('LayerElementNormal')
    normals = nrm_l.find('Normals').props[0]
    uv_l = geo.find('LayerElementUV')
    uvs = uv_l.find('UV').props[0]
    uv_idx = uv_l.find('UVIndex').props[0]

    t = prop70(model, 'Lcl Translation', [0, 0, 0])
    r = prop70(model, 'Lcl Rotation', [0, 0, 0])
    s = prop70(model, 'Lcl Scaling', [1, 1, 1])
    R = euler_xyz_matrix(*r)

    def xform_pos(v):
        v = [v[0] * s[0], v[1] * s[1], v[2] * s[2]]
        return [R[i][0] * v[0] + R[i][1] * v[1] + R[i][2] * v[2] + t[i] for i in range(3)]

    def xform_nrm(n):
        # inverse-transpose of R*S; R is orthonormal so only S needs inverting
        n = [n[0] / s[0], n[1] / s[1], n[2] / s[2]]
        n = [R[i][0] * n[0] + R[i][1] * n[1] + R[i][2] * n[2] for i in range(3)]
        L = math.sqrt(sum(c * c for c in n)) or 1.0
        return [c / L for c in n]

    # --- de-index the polygon-vertex streams into unique glTF vertices --------
    out_v, out_n, out_t, out_i = [], [], [], []
    lookup = {}
    face = []
    for pv, raw in enumerate(poly):
        idx = ~raw if raw < 0 else raw
        pos = xform_pos(verts[idx * 3:idx * 3 + 3])
        nrm = xform_nrm(normals[pv * 3:pv * 3 + 3])
        ui = uv_idx[pv]
        uv = uvs[ui * 2:ui * 2 + 2]
        uv = [uv[0], 1.0 - uv[1]]  # FBX UV origin is bottom-left, glTF top-left
        key = (round(pos[0], 5), round(pos[1], 5), round(pos[2], 5),
               round(nrm[0], 4), round(nrm[1], 4), round(nrm[2], 4),
               round(uv[0], 5), round(uv[1], 5))
        vi = lookup.get(key)
        if vi is None:
            vi = len(out_v) // 3
            lookup[key] = vi
            out_v.extend(pos); out_n.extend(nrm); out_t.extend(uv)
        face.append(vi)
        if raw < 0:  # negative index closes the polygon
            for k in range(1, len(face) - 1):
                out_i.extend((face[0], face[k], face[k + 1]))
            face = []

    # --- normalise: uniform scale to target length, deck top at y=0 ----------
    mn = [min(out_v[i::3]) for i in range(3)]
    mx = [max(out_v[i::3]) for i in range(3)]
    size = [mx[i] - mn[i] for i in range(3)]
    length_axis = size.index(max(size))
    scale = target_length / size[length_axis]
    cx = (mn[0] + mx[0]) * 0.5
    cz = (mn[2] + mx[2]) * 0.5
    top = mx[1]
    for i in range(0, len(out_v), 3):
        out_v[i]     = (out_v[i] - cx) * scale
        out_v[i + 1] = (out_v[i + 1] - top) * scale
        out_v[i + 2] = (out_v[i + 2] - cz) * scale

    print('source bbox %s -> %d verts, %d tris, uniform scale %.5f'
          % ([round(x, 1) for x in size], len(out_v) // 3, len(out_i) // 3, scale))
    print('final bbox  x[%.3f %.3f] y[%.3f %.3f] z[%.3f %.3f]' % (
        min(out_v[0::3]), max(out_v[0::3]), min(out_v[1::3]), max(out_v[1::3]),
        min(out_v[2::3]), max(out_v[2::3])))

    # --- pack a GLB ----------------------------------------------------------
    def pad4(b, fill=b'\0'):
        return b + fill * (-len(b) % 4)

    idx_max = max(out_i)
    idx_fmt, idx_ctype = ('<I', 5125) if idx_max > 65535 else ('<H', 5123)
    bin_idx = b''.join(struct.pack(idx_fmt, i) for i in out_i)
    bin_pos = struct.pack('<%df' % len(out_v), *out_v)
    bin_nrm = struct.pack('<%df' % len(out_n), *out_n)
    bin_uv = struct.pack('<%df' % len(out_t), *out_t)
    with open(png_path, 'rb') as f:
        img = f.read()

    chunks, views, offset = [], [], 0
    for data, target in ((bin_idx, 34963), (bin_pos, 34962),
                         (bin_nrm, 34962), (bin_uv, 34962), (img, None)):
        data = pad4(data)
        v = {'buffer': 0, 'byteOffset': offset, 'byteLength': len(data)}
        if target:
            v['target'] = target
        views.append(v)
        chunks.append(data)
        offset += len(data)
    # byteLength must describe the real payload, not the padding
    views[0]['byteLength'] = len(bin_idx)
    views[1]['byteLength'] = len(bin_pos)
    views[2]['byteLength'] = len(bin_nrm)
    views[3]['byteLength'] = len(bin_uv)
    views[4]['byteLength'] = len(img)
    buf = b''.join(chunks)

    nv = len(out_v) // 3
    gltf = {
        'asset': {'version': '2.0', 'generator': 'skate fbx2glb'},
        'scene': 0,
        'scenes': [{'nodes': [0]}],
        'nodes': [{'mesh': 0, 'name': 'Skateboard'}],
        'meshes': [{'name': 'Skateboard', 'primitives': [{
            'attributes': {'POSITION': 1, 'NORMAL': 2, 'TEXCOORD_0': 3},
            'indices': 0, 'material': 0}]}],
        'materials': [{
            'name': 'Skateboard',
            'pbrMetallicRoughness': {
                'baseColorTexture': {'index': 0},
                'metallicFactor': 0.0,
                'roughnessFactor': 0.65},
            'doubleSided': False}],
        'textures': [{'source': 0, 'sampler': 0}],
        'samplers': [{'magFilter': 9729, 'minFilter': 9987,
                      'wrapS': 10497, 'wrapT': 10497}],
        'images': [{'bufferView': 4, 'mimeType': 'image/png', 'name': 'SkateboardBaseColor'}],
        'accessors': [
            {'bufferView': 0, 'componentType': idx_ctype, 'count': len(out_i),
             'type': 'SCALAR'},
            {'bufferView': 1, 'componentType': 5126, 'count': nv, 'type': 'VEC3',
             'min': [min(out_v[i::3]) for i in range(3)],
             'max': [max(out_v[i::3]) for i in range(3)]},
            {'bufferView': 2, 'componentType': 5126, 'count': nv, 'type': 'VEC3'},
            {'bufferView': 3, 'componentType': 5126, 'count': nv, 'type': 'VEC2'},
        ],
        'bufferViews': views,
        'buffers': [{'byteLength': len(buf)}],
    }

    js = pad4(json.dumps(gltf, separators=(',', ':')).encode('utf-8'), b' ')
    bn = pad4(buf)
    glb = struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(bn))
    glb += struct.pack('<II', len(js), 0x4E4F534A) + js
    glb += struct.pack('<II', len(bn), 0x004E4942) + bn
    with open(out_path, 'wb') as f:
        f.write(glb)
    print('wrote %s (%d bytes)' % (out_path, len(glb)))


if __name__ == '__main__':
    convert(sys.argv[1], sys.argv[2], sys.argv[3])
