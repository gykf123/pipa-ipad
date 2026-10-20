#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pack_package.py v2 — 把琵琶曲工程资源打包成 pipapkg ZIP（格式见 PackageFormat.md）

v2 修正（相对 v1，全部经字节码/数值级验证）：
  1. 网格 pos/nrm、粒子 pos/vel 烤入 GL 基准（Y 向上），转换 = 点乘 B3^T
  2. 相机：view = inv(B @ m)（桌面端 gl_world 后取逆，v1 漏了 inv）；fov/near/far
     逐帧烤入 camera_meta.bin（angle_y 逐帧变化，必须逐帧）
  3. 灯光：过滤 energy<=0；pos/dir 转换 (x,z,-y)
  4. movers.bin：每帧矩阵 to_gl_matrix（B @ M @ B_inv）
  5. bones.bin：保持 q4t3s3 track（App 端按公式现算最终矩阵+插值，与桌面端一致）
  6. debris.bin：烤入墙板撞坏碎块参数（seed 含 id() 不可移植，必须烤）
  7. ao.bin：烤入 SSAO kernel(64x3) 与 noise(4x4x4)（App 端无需复刻 numpy RNG）
  8. defaults：全量渲染参数（v1 缺 light_color/ambient/point_scale/sky/glare 等）
  9. 可见性烘焙改用 GL 数据

用法（在装有资源的机器上跑，纯 Python + numpy，无需 exe 代码）:
    python3 pack_package.py --resources ./resources --out 琵琶曲.pipapkg.zip \
        --name 琵琶曲 --skins char1=zhi.png char2=ao.png --audio pipa_bgm.mp3
"""
import argparse, json, math, os, sys, zipfile
import numpy as np

# ---------------------------------------------------------------- 基础工具

# Blender(z-up) -> GL(y-up)：点/向量左乘 B3^T；矩阵用 B @ M @ B_inv
B3 = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], dtype=np.float32)
BASIS = np.array([[1, 0, 0, 0], [0, 0, 1, 0], [0, -1, 0, 0], [0, 0, 0, 1]], dtype=np.float64)
BASIS_INV = np.linalg.inv(BASIS)

def to_gl_points(a):
    """[N,3] Blender 世界坐标 -> GL 世界坐标"""
    return np.ascontiguousarray(np.asarray(a, dtype=np.float32) @ B3.T, np.float32)

def to_gl_matrix(m):
    """[4,4] Blender 世界矩阵 -> GL 世界矩阵（相似变换）"""
    m = np.asarray(m, dtype=np.float64).reshape(4, 4)
    return (BASIS @ m @ BASIS_INV).astype(np.float32)

def light_direction(yaw_deg, pitch_deg):
    y, p = math.radians(yaw_deg), math.radians(pitch_deg)
    v = np.array([math.cos(p) * math.sin(y), math.sin(p), math.cos(p) * math.cos(y)], dtype=np.float64)
    return (v / max(np.linalg.norm(v), 1e-9)).astype(np.float32)

def perspective_gl(fov_y_deg, aspect, near, far):
    """复刻 mathutil.perspective（度数制竖直 FOV，GL 深度 [-1,1]）"""
    f = 1.0 / math.tan(math.radians(fov_y_deg) * 0.5)
    P = np.zeros((4, 4), dtype=np.float64)
    P[0, 0] = f / max(aspect, 1e-6)
    P[1, 1] = f
    P[2, 2] = (far + near) / (near - far)
    P[2, 3] = 2.0 * far * near / (near - far)
    P[3, 2] = -1.0
    return P

AABB_CORNERS = np.array([[x, y, z] for x in (0, 1) for y in (0, 1) for z in (0, 1)], dtype=np.float64)

def aabb_of(pos):
    p = np.asarray(pos, dtype=np.float64).reshape(-1, 3)
    return p.min(axis=0), p.max(axis=0)

# ---------------------------------------------------------------- 可见性烘焙

def bake_visibility(cam_views, group_aabbs, emissive, alpha_cut,
                    fov_y_deg, aspect, near, far, W=320, H=180, verbose=True):
    """
    保守遮挡剔除：低分辨率深度 splat + 包围盒深度比较（GL 坐标输入）。
    安全性：遮挡物用包围盒【最远】深度 splat，被测物用【最近】深度判定，
    仅当某像素处存在"整体位于本组前方"的遮挡物时才剔除——绝不误删可见物。
    返回 [F, ceil(G/64)] uint64 位图（位=1 可能可见）
    """
    F, G = group_aabbs.shape[0], group_aabbs.shape[1]
    words = (G + 63) // 64
    vis = np.zeros((F, words), dtype=np.uint64)
    bias = 0.0025
    margin = 1.04
    for f in range(F):
        V = cam_views[f]
        VP = perspective_gl(fov_y_deg[f], aspect, near[f], far[f]) @ V
        rects, zns, zfs, state = [], [], [], []
        for g in range(G):
            lo, hi = group_aabbs[f, g, 0], group_aabbs[f, g, 1]
            corners = lo + AABB_CORNERS * (hi - lo)
            clip = np.concatenate([corners, np.ones((8, 1))], axis=1) @ VP.T
            w = clip[:, 3]
            behind = ~(w > 1e-6)
            if behind.all():
                state.append(0); rects.append(None); zns.append(1.0); zfs.append(1.0); continue
            if behind.any():
                state.append(2); rects.append(None); zns.append(1.0); zfs.append(1.0); continue
            ndc = clip[:, :3] / w[:, None]
            if ndc[:, 2].max() < -1.0:
                state.append(0); rects.append(None); zns.append(1.0); zfs.append(1.0); continue
            if ndc[:, 2].min() > 1.0:
                state.append(0); rects.append(None); zns.append(1.0); zfs.append(1.0); continue
            x0 = max(0, int(math.floor((ndc[:, 0].min() * 0.5 + 0.5) * W / margin)))
            x1 = min(W - 1, int(math.ceil((ndc[:, 0].max() * 0.5 + 0.5) * W * margin)))
            y0 = max(0, int(math.floor((ndc[:, 1].min() * 0.5 + 0.5) * H / margin)))
            y1 = min(H - 1, int(math.ceil((ndc[:, 1].max() * 0.5 + 0.5) * H * margin)))
            if x1 < x0 or y1 < y0:
                state.append(0); rects.append(None); zns.append(1.0); zfs.append(1.0); continue
            rects.append((x0, y0, x1, y1))
            zns.append(float(ndc[:, 2].min()))
            zfs.append(float(ndc[:, 2].max()))
            state.append(1)
        D = np.ones((H, W), dtype=np.float32)
        for g in range(G):
            if state[g] != 1:
                continue
            x0, y0, x1, y1 = rects[g]
            D[y0:y1 + 1, x0:x1 + 1] = np.minimum(D[y0:y1 + 1, x0:x1 + 1], zfs[g])
        for g in range(G):
            keep = state[g] == 2 or emissive[g] or alpha_cut[g]
            if not keep and state[g] == 1:
                x0, y0, x1, y1 = rects[g]
                region = D[y0:y1 + 1, x0:x1 + 1]
                keep = bool((region > zns[g] + bias).any())
            if keep:
                vis[f, g >> 6] |= np.uint64(1) << np.uint64(g & 63)
        if verbose and (f % 500 == 0 or f == F - 1):
            n = sum(bin(int(w)).count('1') for w in vis[f])
            print('  visibility %d/%d: %d/%d 组可见' % (f + 1, F, n, G), flush=True)
    return vis

# ---------------------------------------------------------------- 碎块参数

DEBRIS_COUNT = 30
DEBRIS_LIFE = 1.25
DEBRIS_GRAVITY = -17.0
DEBRIS_JUMP = 2.0
DEBRIS_SHADE = 0.65

# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--resources', required=True, help='exe 的 resources 目录')
    ap.add_argument('--out', required=True, help='输出 .pipapkg.zip')
    ap.add_argument('--name', default='pipapkg')
    ap.add_argument('--skins', nargs='*', default=[],
                    help='char1=path.png char2=path.png（64x64 皮肤）')
    ap.add_argument('--audio', default=None)
    ap.add_argument('--no-visibility', action='store_true')
    args = ap.parse_args()

    R = args.resources
    scene = json.load(open(os.path.join(R, 'scene/scene.json'), encoding='utf-8'))
    rig = json.load(open(os.path.join(R, 'animation/rig.json'), encoding='utf-8'))
    scene_bin = os.path.join(R, 'scene/scene.bin')
    rig_bin = os.path.join(R, 'animation/rig.bin')

    f_start, f_end = scene['frame_start'], scene['frame_end']
    frames = f_end - f_start + 1
    res = scene['resolution']
    shutter = float(scene.get('shutter', 0.0))

    def rd(path, meta):
        return np.fromfile(path, dtype='<' + meta['dtype'],
                           count=meta['count'], offset=meta['offset'])

    # ---- 1. 静态/mov 网格 -> meshes.bin + movers.bin ----
    mesh_chunks = {}
    mesh_off = 0
    movers = {}
    mov_off = 0
    groups_meta = []
    rest_aabb = {}
    for g in scene['groups']:
        entry = dict(name=g['name'], color=g.get('color', [1, 1, 1, 1]),
                     emission=g.get('emission', [0, 0, 0]), alpha_cut=bool(g.get('alpha_cut', False)),
                     animated=bool(g.get('animated', False)), verts=g['verts'], indices=g['indices'])
        tex_idx = g.get('texture')
        entry['texture'] = ('textures/' + scene['textures'][tex_idx]['file']) if tex_idx is not None else None
        bufs = {}
        for attr in ('pos', 'nrm', 'uv', 'idx'):
            m = scene['buffers'][g['buf'][attr]]
            arr = rd(scene_bin, m)
            if attr in ('pos', 'nrm'):
                arr = to_gl_points(arr.reshape(-1, 3))      # GL 基准
            elif attr == 'idx':
                arr = arr.astype('<u4')
            else:
                arr = arr.astype('<f4')
            key = '%s_%s' % (g['name'], attr)
            b = arr.tobytes()
            mesh_chunks[key] = b
            bufs[attr] = dict(offset=mesh_off, count=int(arr.size), dtype='f4' if attr != 'idx' else 'u4')
            mesh_off += len(b)
            if attr == 'pos':
                rest_aabb[g['name']] = aabb_of(arr)
        if 'mat' in g.get('buf', {}):
            m = scene['buffers'][g['buf']['mat']]
            arr = rd(scene_bin, m).reshape(frames, 16).astype(np.float64)
            gl_mats = np.stack([to_gl_matrix(arr[i]) for i in range(frames)])   # 逐帧 GL 化
            movers[g['name']] = (mov_off, gl_mats.astype('<f4'))
            mov_off += gl_mats.nbytes
            entry['mat'] = dict(file='movers.bin', offset=movers[g['name']][0],
                                frames=frames, dtype='f4')
        entry['buf'] = bufs
        entry['bounds'] = dict(min=rest_aabb[g['name']][0].tolist(),
                               max=rest_aabb[g['name']][1].tolist())
        groups_meta.append(entry)

    # ---- 2. 角色部件网格 + 骨骼 track ----
    chars_meta = []
    bone_float_off = 0          # 共享 bones.bin 的 float 偏移（显式写入 bone_buffer.offset）
    for cname in ('char1', 'char2'):
        c = rig['characters'][cname]
        nbones = len(c['bones'])
        aw = np.asarray(c['armature_world'], dtype=np.float64).reshape(16)
        parts_meta = []
        for p in c['parts']:
            bufs = {}
            for attr in ('pos', 'nrm', 'uv', 'idx', 'bi', 'bw'):
                if attr not in p['buf']:
                    continue
                m = rig['buffers'][p['buf'][attr]]
                arr = rd(rig_bin, m)
                if attr in ('pos', 'nrm'):
                    arr = to_gl_points(arr.reshape(-1, 3))
                dt = 'u4' if attr == 'idx' else 'f4'
                b = (arr if attr == 'idx' else arr.astype('<f4')).tobytes()
                key = '%s_%s' % (p['name'], attr)
                mesh_chunks[key] = b
                bufs[attr] = dict(offset=mesh_off, count=int(arr.size), dtype=dt)
                mesh_off += len(b)
                if attr == 'pos':
                    rest_aabb[p['name']] = aabb_of(arr)
            lo, hi = rest_aabb[p['name']]
            parts_meta.append(dict(name=p['name'], alpha_cut=bool(p.get('alpha_cut', False)),
                                   verts=p['verts'], indices=p['indices'], buf=bufs,
                                   bounds=dict(min=lo.tolist(), max=hi.tolist())))
        chars_meta.append(dict(name=cname, bones=c['bones'], bone_count=nbones,
                               armature_world=aw.tolist(),      # Blender 空间（App 按公式现算）
                               bone_buffer=dict(file='bones.bin', offset=bone_float_off,
                                                frames=frames,
                                                bones=nbones, dtype='f4',
                                                layout='frame-major-q4t3s3'),
                               parts=parts_meta))
        bone_float_off += frames * nbones * 10

    # ---- 3. 粒子 ----
    pb = scene['particles']
    pt = {}
    pt_chunks = []
    off = 0
    for k, dt in (('pos', 'f4'), ('em', 'f4'), ('vel', 'f4'), ('size', 'f4'), ('offset', 'u4')):
        m = scene['buffers'][pb[k]]
        arr = rd(scene_bin, m)
        if k in ('pos', 'vel'):
            arr = to_gl_points(arr.reshape(-1, 3))
        pt[k] = dict(offset=off, count=int(arr.size), dtype=dt)
        pt_chunks.append(arr.astype('<' + dt).tobytes())
        off += arr.nbytes
    particles_meta = dict(buffer='particles.bin', count=pt['size']['count'],
                          pos=pt['pos'], em=pt['em'], vel=pt['vel'],
                          size=pt['size'], off=pt['offset'])

    # ---- 4. 相机（view = inv(B @ m)，fov/near/far 逐帧） ----
    cam_meta_arr = np.zeros((frames, 4), dtype='<f4')
    cam_views = np.zeros((frames, 4, 4), dtype=np.float64)
    for i, rec in enumerate(scene['camera_track']):
        m = np.asarray(rec['m'], dtype=np.float64).reshape(4, 4)
        cam_views[i] = np.linalg.inv(BASIS @ m)                 # 桌面端 _scene_camera 语义
        fov = math.degrees(float(rec.get('angle_y', 0.6)))
        clip = rec.get('clip') or [0.1, 200.0]
        near = max(float(clip[0]), 0.02)
        far = min(max(float(clip[1]), near + 1.0), 600.0)
        cam_meta_arr[i] = (fov, near, far, 0.0)
    camera_bin = cam_views.astype('<f4').reshape(frames, 16).tobytes()
    camera_meta_bin = cam_meta_arr.tobytes()
    fov_deg = cam_meta_arr[:, 0]
    near_arr = cam_meta_arr[:, 1]
    far_arr = cam_meta_arr[:, 2]

    # ---- 5. 灯光（过滤 energy<=0，GL 转换） ----
    lights = []
    for l in scene['lights']:
        if not l.get('energy') or float(l['energy']) <= 0:
            continue
        p = np.asarray(l['pos'], dtype=np.float64)
        e = dict(type=l['type'], energy=float(l['energy']), color=l['color'],
                 pos=[float(p[0]), float(p[2]), float(-p[1])])
        if l['type'] == 'AREA':
            d = np.asarray(l.get('dir', [0, 0, 0]), dtype=np.float64)
            n = np.linalg.norm(d)
            if n > 1e-9:
                d = d / n
            e['normal'] = [float(d[0]), float(d[2]), float(-d[1])]
        lights.append(e)

    # ---- 6. 碎块（墙板撞坏事件，参数烤入保证可移植） ----
    debris_events = []
    debris_chunks = []
    debris_off = 0
    for gi, g in enumerate(scene['groups']):
        if not g.get('animated') or 'mat' not in g.get('buf', {}):
            continue
        # 本地 AABB 对角线 > 4 视为大结构（复刻 _is_large_structure）
        pm = scene['buffers'][g['buf']['pos']]
        pos_raw = rd(scene_bin, pm).reshape(-1, 3).astype(np.float64)
        lo, hi = pos_raw.min(axis=0), pos_raw.max(axis=0)
        if float(np.linalg.norm(hi - lo)) <= 4.0:
            continue
        mats = rd(scene_bin, scene['buffers'][g['buf']['mat']]).reshape(frames, 4, 4).astype(np.float64)
        d = np.linalg.norm(np.diff(mats[:, :3, 3], axis=0), axis=1)
        for k in np.where(d > DEBRIS_JUMP)[0]:
            bframe = float(f_start + int(k))
            # 复刻 _debris_params 的确定性随机（seed 可移植：组索引 + 帧号）
            seed = (gi * 1000003 + int(bframe)) & 0xFFFFFFFF
            rng = np.random.default_rng(seed)
            # 墙板该帧世界 AABB（GL）
            M = to_gl_matrix(mats[int(k)]).astype(np.float64)
            corners = np.array([[x, y, z, 1] for x in (lo[0], hi[0]) for y in (lo[1], hi[1])
                                for z in (lo[2], hi[2])], dtype=np.float64)
            w = (M @ corners.T).T[:, :3]
            wlo, whi = w.min(axis=0), w.max(axis=0)
            p0 = rng.uniform(wlo, whi, (DEBRIS_COUNT, 3))
            center = (wlo + whi) * 0.5
            out = p0 - center
            out[:, 1] = 0
            out /= np.maximum(np.linalg.norm(out, axis=1, keepdims=True), 1e-6)
            v0 = out * rng.uniform(1.6, 4.2, (DEBRIS_COUNT, 1))
            v0[:, 1] = rng.uniform(2.6, 6.4, DEBRIS_COUNT)
            axis = rng.normal(size=(DEBRIS_COUNT, 3))
            axis /= np.maximum(np.linalg.norm(axis, axis=1, keepdims=True), 1e-6)
            ang = rng.uniform(-9, 9, DEBRIS_COUNT)
            size = rng.uniform(0.13, 0.32, DEBRIS_COUNT)
            head = np.array([[bframe, float(gi), float(wlo[1]), 0.0]], dtype='<f4')
            body = np.concatenate([p0, v0, axis, ang[:, None], size[:, None]], axis=1).astype('<f4')
            debris_events.append(dict(frame=bframe, group=gi, group_name=g['name'],
                                      offset=debris_off, count=DEBRIS_COUNT,
                                      floor=float(wlo[1])))
            debris_chunks.append(head.tobytes() + body.tobytes())
            debris_off += len(debris_chunks[-1])

    # ---- 7. SSAO kernel + noise（烤入，免 App 复刻 numpy RNG） ----
    rng = np.random.default_rng(7)
    kern = rng.normal(size=(64, 3))
    kern /= np.maximum(np.linalg.norm(kern, axis=1, keepdims=True), 1e-9)
    kern *= rng.random((64, 1))
    kern *= np.linspace(0.12, 1, 64)[:, None]
    rng = np.random.default_rng(3)
    nz = rng.normal(size=(4, 4, 3))
    nz[:, :, 2] = 0
    nz /= np.maximum(np.linalg.norm(nz, axis=2, keepdims=True), 1e-9)
    noise = np.zeros((4, 4, 4), dtype=np.float32)
    noise[:, :, :3] = nz * 0.5 + 0.5
    noise[:, :, 3] = 1
    ao_bin = np.ascontiguousarray(kern, '<f4').tobytes() + np.ascontiguousarray(noise, '<f4').tobytes()

    # ---- 8. 可见性烘焙（GL 数据） ----
    vis_meta = None
    vis_bytes = None
    if not args.no_visibility:
        print('烘焙每帧可见性（保守遮挡剔除，GL 基准）...', flush=True)
        G = len(groups_meta)
        aabb = np.zeros((frames, G, 2, 3), dtype=np.float64)
        for gi, g in enumerate(groups_meta):
            lo, hi = np.asarray(g['bounds']['min']), np.asarray(g['bounds']['max'])
            if g['animated'] and 'mat' in g:
                M = movers[g['name']][1].reshape(frames, 4, 4).astype(np.float64)
                corners = lo + AABB_CORNERS * (hi - lo)
                tc = np.einsum('fij,aj->fai', M[:, :3, :3], corners) + M[:, None, :3, 3]
                aabb[:, gi, 0] = tc.min(axis=1)
                aabb[:, gi, 1] = tc.max(axis=1)
            else:
                aabb[:, gi, 0] = lo
                aabb[:, gi, 1] = hi
        vis = bake_visibility(cam_views, aabb,
                              emissive=np.array([any(g['emission']) for g in groups_meta]),
                              alpha_cut=np.array([g['alpha_cut'] for g in groups_meta]),
                              fov_y_deg=fov_deg, aspect=res[0] / res[1],
                              near=near_arr, far=far_arr)
        vis_meta = dict(buffer='visibility.bin', frames=frames, groups=G,
                        layout='frame-major-bitmask')
        vis_bytes = vis.astype('<u8').tobytes()
        n_vis = int(sum(bin(int(w)).count('1') for w in vis.reshape(-1)))
        print('可见性位图: %d 字节, 平均每组每帧 %.1f%% 可见'
              % (len(vis_bytes), 100.0 * n_vis / (frames * G)), flush=True)

    # ---- 9. 组装 ZIP ----
    meshes_bin = b''.join(mesh_chunks[k] for k in mesh_chunks)
    movers_bin = b''.join(v[1].tobytes() for v in movers.values())
    bones_bin = b''.join(
        rd(rig_bin, rig['buffers'][rig['characters'][c]['track']])
        .reshape(frames, len(rig['characters'][c]['bones']), 10).astype('<f4').tobytes()
        for c in ('char1', 'char2'))
    particles_bin = b''.join(pt_chunks)
    debris_bin = b''.join(debris_chunks)

    skins = {}
    for s in args.skins:
        k, v = s.split('=', 1)
        skins[k] = v

    pkg = dict(
        format='pipapkg', version=2, name=args.name,
        fps=scene['fps'], frame_start=f_start, frame_end=f_end,
        resolution=res, shutter=shutter,
        world=dict(background=scene.get('world_color', [0.05, 0.05, 0.05])),
        defaults=dict(
            exposure=1.0, gamma=2.2, tonemap='filmic',
            bloom=True, bloom_threshold=1.05, bloom_strength=0.35,
            glare=True, glare_threshold=2.9, glare_strength=0.533,
            glare_size=1.083, glare_smoothness=0.1,
            shadow=True, shadow_samples=16, shadow_softness=1.8, shadow_distance=34.0,
            ao=True, ao_samples=24, ao_intensity=1.15, ao_radius=0.55,
            ssr=False,                       # 交付版关闭反光
            ambient_intensity=3.4,
            light_color=[1.0, 0.96, 0.9],
            sky_color=[0.62, 0.64, 0.68], ground_color=[0.4, 0.41, 0.44],
            spec_strength=0.55, roughness=0.45,
            point_scale=2.0, point_soft=0.8,
            particle_scale=1.0, particle_streak=1.0, particle_width=1.8,
            debris=dict(count=DEBRIS_COUNT, life=DEBRIS_LIFE, gravity=DEBRIS_GRAVITY,
                        jump=DEBRIS_JUMP, shade=DEBRIS_SHADE)),
        sun=dict(dir=light_direction(42.0, 56.0).tolist(),
                 color=[1.0, 0.96, 0.9], intensity=3.4,
                 shadow_softness=1.8, shadow_samples=16),
        lights=lights,
        camera=dict(buffer='camera.bin', meta_buffer='camera_meta.bin', frames=frames,
                    fov_unit='degrees'),
        groups=groups_meta,
        characters=chars_meta,
        particles=particles_meta,
        visibility=vis_meta,
        debris=dict(buffer='debris.bin', events=debris_events),
        ao=dict(buffer='ao.bin', kernel_count=64, noise_size=4),
        audio='audio.mp3' if args.audio else None,
    )
    for c in pkg['characters']:
        c['skin'] = ('skins/%s.png' % c['name']) if c['name'] in skins else None

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with zipfile.ZipFile(args.out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.writestr('package.json', json.dumps(pkg, ensure_ascii=False, indent=1))
        z.writestr('meshes.bin', meshes_bin)
        if movers_bin:
            z.writestr('movers.bin', movers_bin)
        z.writestr('bones.bin', bones_bin)
        z.writestr('camera.bin', camera_bin)
        z.writestr('camera_meta.bin', camera_meta_bin)
        z.writestr('particles.bin', particles_bin)
        if vis_bytes is not None:
            z.writestr('visibility.bin', vis_bytes)
        if debris_bin:
            z.writestr('debris.bin', debris_bin)
        z.writestr('ao.bin', ao_bin)
        for t in scene['textures']:
            p = os.path.join(R, 'scene/textures', t['file'])
            if os.path.isfile(p):
                z.write(p, 'textures/' + t['file'])
        for k, v in skins.items():
            z.write(v, 'skins/%s.png' % k)
        if args.audio:
            z.write(args.audio, 'audio.mp3')
    sz = os.path.getsize(args.out) / 1e6
    print('完成 -> %s (%.1f MB)' % (args.out, sz), flush=True)
    print('  组 %d | 角色 %d | 粒子 %d | 帧 %d @ %dfps | 碎块事件 %d | 灯光 %d'
          % (len(groups_meta), len(chars_meta), particles_meta['count'], frames,
             scene['fps'], len(debris_events), len(lights)), flush=True)

if __name__ == '__main__':
    main()
