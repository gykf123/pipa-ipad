#!/usr/bin/env python3
"""creeper_flower_scene5.v2.zip 软渲染抽查（numpy + PIL，不依赖 Metal）。

用途：App 无法本地跑（iOS）时，用独立复刻的软渲染管线验证转换产物可渲染：
透视投影（camera_meta fov/near/far）-> 视图矩阵变换 -> painter's algorithm
-> 三角形填充 + atlas 采样 + 方向光。抽 3 帧拼一张图。

用法：python3 softrender_check.py <v2包.zip> [输出.png] [帧...]
"""
import json
import sys
import zipfile

import numpy as np
from PIL import Image, ImageDraw


def load(zpath):
    z = zipfile.ZipFile(zpath)
    pkg = json.loads(z.read('package.json'))
    f = np.frombuffer(z.read('meshes.bin'), dtype='<f4')
    u = np.frombuffer(z.read('meshes.bin'), dtype='<u4')
    movers = np.frombuffer(z.read('movers.bin'), dtype='<f4').reshape(-1, 16)
    cam = np.frombuffer(z.read(pkg['camera']['buffer']), dtype='<f4').reshape(-1, 16)
    meta_fn = pkg['camera'].get('meta_buffer') or pkg['camera'].get('meta_file')
    meta = np.frombuffer(z.read(meta_fn), dtype='<f4').reshape(-1, 4)
    texs = {}
    for t in pkg.get('textures', []) or []:
        fn = t.get('file') if isinstance(t, dict) else t
        if fn and fn in z.namelist():
            texs[fn] = np.asarray(Image.open(z.open(fn)).convert('RGBA'), dtype=np.float32)
    return pkg, f, u, movers, cam, meta, texs


def project(fov_deg, near, far, aspect):
    f = 1.0 / np.tan(np.radians(fov_deg) / 2.0)
    return np.array([
        [f / aspect, 0, 0, 0],
        [0, f, 0, 0],
        [0, 0, (far + near) / (near - far), 2 * far * near / (near - far)],
        [0, 0, -1, 0],
    ], dtype=np.float64)  # GL 约定：NDC z ∈ [-1,1]，y up


def render_frame(pkg, f, u, movers, cam, meta, texs, frame, W=640, H=360, bg=(24, 26, 30)):
    frames = pkg['frame_end'] - pkg['frame_start'] + 1
    V = cam[frame].reshape(4, 4)
    fov = meta[frame][0]
    near = max(meta[frame][1], 0.02)
    far = max(meta[frame][2], near + 1)
    P = project(fov, near, far, W / H)
    img = Image.new('RGB', (W, H), bg)
    dr = ImageDraw.Draw(img)
    sun = np.array(pkg['sun']['dir'], dtype=np.float64)
    sun /= np.linalg.norm(sun)
    # 收集所有三角形（世界坐标 + 组贴图），按深度排序
    tris = []
    for gi, g in enumerate(pkg['groups']):
        b = g['buf']
        po = b['pos']['offset'] // 4
        no = b['nrm']['offset'] // 4
        uo = b['uv']['offset'] // 4
        io = b['idx']['offset'] // 4
        pos = f[po:po + b['pos']['count']].reshape(-1, 3).astype(np.float64)
        nrm = f[no:no + b['nrm']['count']].reshape(-1, 3).astype(np.float64)
        uv = f[uo:uo + b['uv']['count']].reshape(-1, 2)
        idx = u[io:io + b['idx']['count']].astype(np.int64)
        M = movers[gi * frames + frame].reshape(4, 4)
        wp = np.concatenate([pos, np.ones((len(pos), 1))], axis=1) @ M.T
        # 法线用 mat3(M)（平移不影响）
        wn = nrm @ M[:3, :3].T
        wn /= np.maximum(np.linalg.norm(wn, axis=1, keepdims=True), 1e-8)
        vp = wp @ V.T
        cp = vp @ P.T
        w = cp[:, 3:4]
        ok = (np.abs(w[:, 0]) > 1e-6)
        ndc = cp[:, :3] / np.where(ok.reshape(-1, 1), w, 1.0)
        sx = (ndc[:, 0] * 0.5 + 0.5) * W
        sy = (1.0 - (ndc[:, 1] * 0.5 + 0.5)) * H
        sz = ndc[:, 2]
        tex = texs.get(g.get('texture'))
        base = np.array(g.get('color') or [0.8, 0.8, 0.8, 1.0], dtype=np.float64)[:3]
        for t0, t1, t2 in idx.reshape(-1, 3):
            if not (ok[t0] and ok[t1] and ok[t2]):
                continue
            if min(sz[t0], sz[t1], sz[t2]) < -1 or max(sz[t0], sz[t1], sz[t2]) > 1:
                continue
            pts = [(sx[t0], sy[t0]), (sx[t1], sy[t1]), (sx[t2], sy[t2])]
            depth = float(np.mean([sz[t0], sz[t1], sz[t2]]))
            # 面法线（视图空间 Lambert）
            e1, e2 = wp[t1][:3] - wp[t0][:3], wp[t2][:3] - wp[t0][:3]
            fn_ = np.cross(e1, e2)
            ln = np.linalg.norm(fn_)
            if ln < 1e-9:
                continue
            fn_ /= ln
            lam = max(0.0, float(fn_ @ (-sun)))
            # 贴图采样（三角形质心 UV）
            col = base
            if tex is not None:
                cu, cv = uv[[t0, t1, t2]].mean(axis=0)
                tx = min(max(int(cu * tex.shape[1]), 0), tex.shape[1] - 1)
                ty = min(max(int((1 - cv) * tex.shape[0]), 0), tex.shape[0] - 1)
                col = tex[ty, tx][:3] / 255.0
                if tex[ty, tx][3] < 128:
                    continue
            shade = 0.25 + 0.75 * lam
            rgb = tuple(int(min(255, c * 255 * shade)) for c in col)
            tris.append((depth, pts, rgb))
    # painter：远 -> 近
    tris.sort(key=lambda x: -x[0])
    for _, pts, rgb in tris:
        dr.polygon(pts, fill=rgb, outline=rgb)
    return img


def main():
    zpath = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else 'creeper_softrender.png'
    frames = [int(x) for x in sys.argv[3:]] or [0, 60, 119]
    pkg, f, u, movers, cam, meta, texs = load(zpath)
    nf = pkg['frame_end'] - pkg['frame_start'] + 1
    frames = [fr for fr in frames if 0 <= fr < nf]
    W, H = 640, 360
    canvas = Image.new('RGB', (W, H * len(frames)), (12, 13, 16))
    for i, fr in enumerate(frames):
        im = render_frame(pkg, f, u, movers, cam, meta, texs, fr, W, H)
        canvas.paste(im, (0, i * H))
    canvas.save(out)
    print(f"软渲染完成: {out}（帧 {frames}，组 {len(pkg['groups'])}）")


if __name__ == '__main__':
    main()
