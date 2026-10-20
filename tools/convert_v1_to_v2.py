#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pipapkg v1 -> v2 转换器

把按 v1 设计导出的 .pipapkg.zip（meshes/indices 顶层段、8 标量数组、
frame-major movers、bones/movers 双份）转换为 PipaRender 可导入的 v2 格式。

v1 -> v2 映射:
    meshes.attributes(8 标量数组)  -> meshes.bin 内 pos(3)/nrm(3)/uv(2) 每顶点分量连续
    indices.bin(独立文件)          -> 合并进 meshes.bin 尾部，组经 buf.idx 定位
    meshes.groups[](vertex_offset) -> 顶层 groups[]（buf 偏移块 + bounds + color 等）
    movers [frames][groups][16]    -> 组主序 [groups][frames][16]，各组 mat.offset 定位
    bones(q4t3s3, pivot 局部)      -> 丢弃（movers 已含全部动画，世界矩阵语义更直接）
    camera / camera_meta           -> 透传（语义一致）
    textures / skins               -> 透传
    animation 语义段               -> 丢弃（App 不需要，渲染数据已逐帧烤入）

用法:
    python3 convert_v1_to_v2.py <in.zip> [-o out.zip] [--skin skins/char1.png]
                                       [--resolution 1920x1080] [--no-hat]
"""
import json, sys, zipfile, shutil, os
import numpy as np

# 渲染默认值（与琵琶曲样例一致，见 PackageFormat.md §8）
DEFAULTS = {
    "exposure": 1.0, "gamma": 2.2, "tonemap": "filmic",
    "bloom": True, "bloom_threshold": 1.05, "bloom_strength": 0.35,
    "glare": True, "glare_threshold": 2.9, "glare_strength": 0.533,
    "glare_size": 1.083, "glare_smoothness": 0.1,
    "shadow": True, "shadow_samples": 16, "shadow_softness": 1.8, "shadow_distance": 34.0,
    "ao": True, "ao_samples": 24, "ao_intensity": 1.15, "ao_radius": 0.55,
    "ssr": False, "ambient_intensity": 3.4,
    "light_color": [1.0, 0.96, 0.9],
    "sky_color": [0.62, 0.64, 0.68], "ground_color": [0.4, 0.41, 0.44],
    "spec_strength": 0.55, "roughness": 0.45,
    "point_scale": 2.0, "point_soft": 0.8,
    "particle_scale": 1.0, "particle_streak": 1.0, "particle_width": 1.8,
}
SUN = {"dir": [0.37, 0.83, 0.42], "color": [1.0, 0.96, 0.9], "intensity": 3.4,
       "shadow_softness": 1.8, "shadow_samples": 16}


def convert(src, dst, skin=None, resolution=(1920, 1080), keep_hat=True):
    zin = zipfile.ZipFile(src)
    pkg = json.loads(zin.read('package.json').decode('utf-8'))
    if pkg.get('version') == 2 and 'groups' in pkg:
        print("已是 v2，无需转换"); return

    frames = pkg['frames']
    fps = pkg['fps']
    m = pkg['meshes']
    vc = m['vertex_count']
    attrs = m['attributes']
    ngroups = len(m['groups'])

    # ---------- meshes.bin: 8 标量数组 -> pos/nrm/uv 每顶点分量连续 ----------
    raw = np.frombuffer(zin.read(m['file']), dtype='<f4')
    assert raw.size == vc * len(attrs), f"meshes.bin 大小不符: {raw.size} != {vc*len(attrs)}"
    A = {a: raw[i*vc:(i+1)*vc] for i, a in enumerate(attrs)}

    new_mesh = bytearray()
    groups_out = []
    idx_all = np.frombuffer(zin.read(pkg['indices']['file']), dtype='<u4')

    # movers: [frames][groups][16] -> 组主序 [groups][frames][16]
    mv = np.frombuffer(zin.read(pkg['movers']['file']), dtype='<f4').reshape(frames, ngroups, 16)
    mv_group_major = mv.transpose(1, 0, 2).copy()   # [groups, frames, 16]

    # 静置 AABB（用第 0 帧矩阵变换原始顶点）
    rest_pos = np.stack([A['px'], A['py'], A['pz']], axis=1)  # [vc, 3]
    rest_pos1 = np.concatenate([rest_pos, np.ones((vc, 1), np.float32)], axis=1)

    # 第一遍：写 pos/nrm/uv（SoA 按组拼接），记录每组 offset
    pos_off, nrm_off, uv_off = {}, {}, {}
    for gi, g in enumerate(m['groups']):
        v0, n = g['vertex_offset'], g['vertex_count']
        if not keep_hat and g['name'] == 'hat':
            continue
        pos_off[gi] = len(new_mesh)
        new_mesh += np.stack([A['px'][v0:v0+n], A['py'][v0:v0+n], A['pz'][v0:v0+n]],
                             axis=1).astype('<f4').tobytes()
    for gi, g in enumerate(m['groups']):
        v0, n = g['vertex_offset'], g['vertex_count']
        if not keep_hat and g['name'] == 'hat':
            continue
        nrm_off[gi] = len(new_mesh)
        new_mesh += np.stack([A['nx'][v0:v0+n], A['ny'][v0:v0+n], A['nz'][v0:v0+n]],
                             axis=1).astype('<f4').tobytes()
    for gi, g in enumerate(m['groups']):
        v0, n = g['vertex_offset'], g['vertex_count']
        if not keep_hat and g['name'] == 'hat':
            continue
        uv_off[gi] = len(new_mesh)
        new_mesh += np.stack([A['u'][v0:v0+n], A['v'][v0:v0+n]],
                             axis=1).astype('<f4').tobytes()
    # 第二遍：indices 追加尾部，全局顶点索引 -> 组内局部索引（v2 每组独立顶点区间）
    idx_base = len(new_mesh)
    idx_off = {}
    for gi, g in enumerate(m['groups']):
        if not keep_hat and g['name'] == 'hat':
            continue
        v0 = g['vertex_offset']
        i0, ic = g['index_offset'], g['index_count']
        idx_off[gi] = idx_base + (len(new_mesh) - idx_base)
        local = (idx_all[i0:i0+ic] - v0).astype('<u4')   # 全局 -> 组内局部
        assert local.min() >= 0 and local.max() < g['vertex_count']
        new_mesh += local.tobytes()

    for gi, g in enumerate(m['groups']):
        if not keep_hat and g['name'] == 'hat':
            continue
        v0, n = g['vertex_offset'], g['vertex_count']
        i0, ic = g['index_offset'], g['index_count']
        # 静置 AABB
        M0 = mv[0, gi].reshape(4, 4).astype(np.float64)
        wp = (rest_pos1[v0:v0+n] @ M0.T)[:, :3]
        lo, hi = wp.min(axis=0), wp.max(axis=0)
        groups_out.append({
            "name": g['name'],
            "texture": skin,                      # 角色部件统一皮肤（UV 已按皮肤布局）
            "color": [0.8, 0.8, 0.8, 1.0],
            "emission": [0, 0, 0],
            "alpha_cut": False,
            "animated": True,
            "bounds": {"min": [float(x) for x in lo], "max": [float(x) for x in hi]},
            "verts": n, "indices": ic,
            "buf": {
                "pos": {"offset": pos_off[gi], "count": n * 3, "dtype": "f4"},
                "nrm": {"offset": nrm_off[gi], "count": n * 3, "dtype": "f4"},
                "uv":  {"offset": uv_off[gi],  "count": n * 2, "dtype": "f4"},
                "idx": {"offset": idx_off[gi], "count": ic, "dtype": "u4"},
            },
            "mat": {"file": "movers.bin", "offset": gi * frames * 16 * 4,
                    "frames": frames, "dtype": "f4"},
        })

    # ---------- 顶层 v2 ----------
    v2 = {
        "format": "pipapkg", "version": 2,
        "name": pkg.get('name', 'converted'),
        "fps": fps, "frame_start": 0, "frame_end": frames - 1,
        "resolution": list(resolution),
        "shutter": 1.0 / fps,
        "world": {"background": [0.05, 0.05, 0.05]},
        "defaults": DEFAULTS,
        "sun": SUN, "lights": [],
        "camera": {"buffer": "camera.bin", "meta_buffer": "camera_meta.bin",
                   "frames": frames, "fov_unit": "degrees"},
        "groups": groups_out,
        "characters": [],           # v1 盒模型由 movers 驱动，无需 characters 蒙皮
        "particles": None, "visibility": None, "debris": None, "ao": None,
        "audio": None,
    }
    # 透传的可选文件
    for fn in ('camera.bin', 'camera_meta.bin'):
        if fn in zin.namelist():
            v2['camera'][('buffer' if 'camera.' in fn else 'meta_buffer')] = fn
    tex_files = [t['file'] for t in pkg.get('textures', []) if t.get('file') in zin.namelist()]
    if pkg.get('audio') and pkg['audio'] in zin.namelist():
        v2['audio'] = pkg['audio']

    # ---------- 写包 ----------
    with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zout:
        zout.writestr('package.json', json.dumps(v2, ensure_ascii=False, indent=1))
        zout.writestr('meshes.bin', bytes(new_mesh))
        zout.writestr('movers.bin', mv_group_major.astype('<f4').tobytes())
        zout.writestr('camera.bin', zin.read('camera.bin'))
        zout.writestr('camera_meta.bin', zin.read('camera_meta.bin'))
        for fn in tex_files:
            zout.writestr(fn, zin.read(fn))
        if v2['audio']:
            zout.writestr(v2['audio'], zin.read(v2['audio']))
    zin.close()
    print(f"转换完成: {dst}")
    print(f"  groups={len(groups_out)}  frames={frames}  verts={vc}")
    print(f"  meshes.bin={len(new_mesh)}B  movers.bin={mv_group_major.nbytes}B（组主序重排）")
    if pkg.get('bones'):
        print(f"  [注意] 源 bones.bin 已丢弃（movers 已含全部动画，世界矩阵语义）")


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('-o', '--out', default=None)
    ap.add_argument('--skin', default='skins/char1.png', help='角色部件统一贴图（默认 skins/char1.png）')
    ap.add_argument('--resolution', default='1920x1080')
    ap.add_argument('--no-hat', action='store_true', help='剔除 hat 组（帽子层突兀时可选）')
    a = ap.parse_args()
    dst = a.out or os.path.splitext(a.src)[0] + '.v2.zip'
    w, h = map(int, a.resolution.lower().split('x'))
    skin = a.skin
    # 皮肤不存在则置空
    zz = zipfile.ZipFile(a.src)
    if skin not in zz.namelist():
        print(f"[warn] {skin} 不在包内，组将无贴图")
        skin = None
    zz.close()
    convert(a.src, dst, skin=skin, resolution=(w, h), keep_hat=not a.no_hat)


if __name__ == '__main__':
    main()
