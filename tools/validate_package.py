#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pipapkg v2 包验证器 —— 任何项目导出 .pipapkg.zip 后用它验证能否被 PipaRender 导入。

用法:
    python3 validate_package.py <包.zip> [-v]

检查项（分级）:
    FAIL  结构性缺失/越界 —— App 导入必失败
    WARN  可用但影响渲染质量或有歧义
    PASS  正常
对照规范: PackageFormat.md §1-9
"""
import json, struct, sys, zipfile, math
import numpy as np

F4, U4 = 4, 4

class Report:
    def __init__(self):
        self.items = []   # (level, msg)
        self.fails = 0
        self.warns = 0
    def add(self, level, msg):
        self.items.append((level, msg))
        if level == 'FAIL': self.fails += 1
        elif level == 'WARN': self.warns += 1
    def fail(self, m): self.add('FAIL', m)
    def warn(self, m): self.add('WARN', m)
    def ok(self, m):   self.add('PASS', m)
    def info(self, m): self.add('INFO', m)

def validate(path, verbose=False):
    r = Report()
    zf = zipfile.ZipFile(path)
    names = set(zf.namelist())
    zf_bad = zf.testzip()
    if zf_bad:
        r.fail(f"ZIP 损坏: {zf_bad}"); return r
    r.ok("ZIP 结构完整")

    # ---------- package.json ----------
    if 'package.json' not in names:
        r.fail("缺少 package.json"); return r
    try:
        pkg = json.loads(zf.read('package.json').decode('utf-8'))
    except Exception as e:
        r.fail(f"package.json 解析失败: {e}"); return r
    r.ok("package.json 可解析")

    if pkg.get('format') != 'pipapkg':
        r.fail(f"format={pkg.get('format')!r}，应为 'pipapkg'")
    ver = pkg.get('version')
    if ver != 2:
        r.fail(f"version={ver}，当前读取端只支持 v2（v1 设计需经 pack_package.py 转换）")
        if 'meshes' in pkg or 'indices' in pkg:
            r.info("检测到 v1 结构（meshes/indices 顶层段、attributes 标量数组）")
    else:
        r.ok("format/version 正确 (pipapkg v2)")

    # ---------- 帧区间 ----------
    fps = pkg.get('fps')
    if not isinstance(fps, (int, float)) or fps <= 0:
        r.fail(f"fps={fps!r} 无效")
    fs, fe = pkg.get('frame_start'), pkg.get('frame_end')
    if fs is None or fe is None:
        r.fail("缺少 frame_start/frame_end")
        frames = pkg.get('frames')
    else:
        if not (isinstance(fs, int) and isinstance(fe, int)):
            r.fail(f"frame_start/end 应为 int，得到 {fs!r},{fe!r}")
        if fe < fs:
            r.fail(f"frame_end({fe}) < frame_start({fs})")
        frames = fe - fs + 1
        r.ok(f"帧区间 {fs}..{fe}（{frames} 帧 @ {fps}fps）")

    def size_of(fn):
        return zf.getinfo(fn).file_size if fn in names else None

    def read_f4(fn, count, float_offset=0):
        """读 count 个 float32（可从 float_offset 起）"""
        with zf.open(fn) as f:
            f.seek(float_offset * F4)
            buf = f.read(count * F4)
        if len(buf) < count * F4:
            r.fail(f"{fn}: 需要 {count*F4}B 实际仅 {len(buf)}B")
            return np.zeros(count, dtype=np.float32)
        return np.frombuffer(buf, dtype='<f4')

    def _read_at(z, fn, byte_off, nbytes):
        with z.open(fn) as f:
            f.seek(byte_off)
            return f.read(nbytes)

    # ---------- camera ----------
    cam = pkg.get('camera') or {}
    cam_file = cam.get('buffer') or cam.get('file')
    meta_file = cam.get('meta_buffer') or cam.get('meta_file')
    if not cam_file or cam_file not in names:
        r.fail(f"camera.bin 缺失（camera.buffer={cam_file!r}）")
    else:
        expect = frames * 16 * F4
        got = size_of(cam_file)
        if got != expect:
            r.fail(f"{cam_file} 大小 {got}B != frames×64B（{expect}B）")
        else:
            r.ok(f"camera.bin 大小正确（{frames} 帧 × 16 f4 行主序）")
        # 抽样: 矩阵可逆
        mv = read_f4(cam_file, frames * 16).reshape(-1, 4, 4)
        if len(mv):
            idxs = [0, len(mv)//2, len(mv)-1] if len(mv) > 2 else list(range(len(mv)))
            bad = [i for i in idxs if abs(np.linalg.det(mv[i].astype(np.float64))) < 1e-9]
            if bad:
                r.fail(f"{cam_file} 帧 {bad} 视图矩阵奇异（不可逆）")
            else:
                r.ok("视图矩阵抽样可逆")
    if not meta_file or meta_file not in names:
        r.fail(f"camera_meta.bin 缺失（camera.meta_buffer={meta_file!r}）")
    else:
        expect = frames * 4 * F4
        if size_of(meta_file) != expect:
            r.fail(f"{meta_file} 大小 {size_of(meta_file)}B != {expect}B")
        else:
            meta = read_f4(meta_file, frames * 4).reshape(-1, 4)
            fov, near, far = meta[:, 0], meta[:, 1], meta[:, 2]
            if np.any((fov <= 1) | (fov > 170)):
                r.warn(f"fov_deg 抽样异常: min={fov.min():.1f} max={fov.max():.1f}")
            if np.any(near <= 0) or np.any(far <= near):
                r.fail(f"near/far 异常: near∈[{near.min():.4g},{near.max():.4g}] far∈[{far.min():.4g},{far.max():.4g}]")
            else:
                r.ok(f"camera_meta 正常（fov∈[{fov.min():.1f},{fov.max():.1f}] near/far 有序）")

    # ---------- groups ----------
    groups = pkg.get('groups') or []
    if not groups:
        r.fail("groups[] 为空 —— 没有任何可渲染网格")
    mesh_file = None
    for g in groups:
        gn = g.get('name', '?')
        buf = g.get('buf') or {}
        mf = (g.get('mat') or {}).get('file')
        if mf and mf not in (None, mesh_file):
            pass
        for attr, per in (('pos', 3), ('nrm', 3), ('uv', 2), ('idx', None)):
            ref = buf.get(attr)
            if ref is None:
                if attr == 'idx':
                    r.fail(f"组 {gn}: buf.idx 缺失（v2 索引内嵌 meshes.bin，非独立 indices.bin）")
                elif attr in ('pos', 'nrm'):
                    r.fail(f"组 {gn}: buf.{attr} 缺失")
                else:
                    r.warn(f"组 {gn}: buf.uv 缺失（无法贴图）")
                continue
            fn = ref.get('file') or mesh_file or 'meshes.bin'
            if fn not in names:
                r.fail(f"组 {gn}: buf.{attr} 指向不存在的文件 {fn}"); continue
            if mesh_file is None:
                mesh_file = fn
            sz = size_of(fn)
            off, cnt = ref.get('offset', 0), ref.get('count', 0)
            isz = U4 if attr == 'idx' else F4
            if off + cnt * isz > sz:
                r.fail(f"组 {gn}: buf.{attr} [offset={off},count={cnt}] 越界（{fn} 仅 {sz}B）")
            if attr == 'idx':
                # 真读索引：越界 -> drawIndexed 读别组内存（花屏/崩管线）；并查退化三角形
                idx = np.frombuffer(_read_at(zf, fn, off, cnt * U4), dtype='<u4') if cnt else np.zeros(0, '<u4')
                vc = g.get('verts')
                if vc is not None and cnt and int(idx.max()) >= vc:
                    r.fail(f"组 {gn}: 索引越界 max={int(idx.max())} >= verts={vc}（drawIndexed 将读到别组数据）")
                if cnt and cnt % 3:
                    r.fail(f"组 {gn}: 索引数 {cnt} 不是 3 的倍数")
                if cnt >= 3:
                    tris = idx.reshape(-1, 3)
                    if (tris[:,0]==tris[:,1]).any() or (tris[:,1]==tris[:,2]).any():
                        r.warn(f"组 {gn}: 存在退化三角形（索引重复）")
            if attr == 'uv' and cnt >= 2:
                uv = read_f4(fn, cnt, float_offset=off // F4).reshape(-1, 2)
                if uv.min() < -0.001 or uv.max() > 1.001:
                    r.warn(f"组 {gn}: UV 越界 [{uv.min():.3f},{uv.max():.3f}]"
                           "（albedo sampler 为 repeat，源数据约定不同时贴图会重复错位）")
        # 组级字段
        for f, req in (('color', 'warn'), ('bounds', 'fail'), ('texture', 'info')):
            if f not in g:
                if f == 'bounds':
                    r.warn(f"组 {gn}: 缺 bounds（可见性/视锥剔除退化为全量绘制）")
                elif f == 'color' and g.get('texture') in (None, 'null'):
                    r.warn(f"组 {gn}: 无贴图且无 color（将渲染为黑）")
                else:
                    r.ok(f"组 {gn}: 字段齐全")
        # 引用贴图存在性
        tex = g.get('texture')
        if tex and tex not in names:
            r.fail(f"组 {gn}: 贴图 {tex} 不在包内")
    if mesh_file and groups:
        r.ok(f"网格数据文件: {mesh_file}")

    # 顶点/索引数值抽查（第一个组）
    if groups and mesh_file in names:
        g0 = groups[0]
        b = g0.get('buf', {})
        pos = b.get('pos'); nrm = b.get('nrm'); idx = b.get('idx')
        if pos and idx:
            vcount = pos['count'] // 3
            verts = read_f4(mesh_file, pos['offset']//F4 + pos['count'])[pos['offset']//F4 - (pos['offset']//F4):] if False else None
            with zf.open(mesh_file) as f:
                f.seek(pos['offset'])
                pv = np.frombuffer(f.read(pos['count']*F4), dtype='<f4').reshape(-1, 3)
                if nrm:
                    f.seek(nrm['offset'])
                    nv = np.frombuffer(f.read(nrm['count']*F4), dtype='<f4').reshape(-1, 3)
                    ln = np.linalg.norm(nv.astype(np.float64), axis=1)
                    if np.any(np.abs(ln - 1) > 0.05):
                        r.warn(f"组 {g0['name']}: 法线未归一化（长度范围 [{ln.min():.3f},{ln.max():.3f}]）")
                    else:
                        r.ok("法线抽样已归一化")
                f.seek(idx['offset'])
                iv = np.frombuffer(f.read(idx['count']*U4), dtype='<u4')
                if iv.size and iv.max() >= vcount:
                    r.fail(f"组 {g0['name']}: 索引越界 max={iv.max()} >= 顶点数 {vcount}")
                else:
                    r.ok(f"组 {g0['name']}: 索引范围正常（max={int(iv.max()) if iv.size else '-'} < {vcount}）")

    # ---------- movers ----------
    anim = [g for g in groups if g.get('animated')]
    if anim:
        for g in anim:
            mt = g.get('mat') or {}
            mf = mt.get('file')
            if not mf or mf not in names:
                r.fail(f"animated 组 {g['name']}: mat.file={mf!r} 缺失"); continue
            expect = frames * 16 * F4
            off = mt.get('offset', 0)
            if off + expect > size_of(mf):
                r.fail(f"animated 组 {g['name']}: movers 区间越界（offset={off} 需 {expect}B，{mf} 共 {size_of(mf)}B）")
            else:
                r.ok(f"movers 组 {g['name']} 区间正确")

    # ---------- characters / bones ----------
    chars = pkg.get('characters') or []
    bone_running = {}   # file -> 下一段起始 float 偏移（无 offset 字段时按顺序累加）
    for c in chars:
        cn = c.get('name', '?')
        bb = c.get('bone_buffer') or {}
        bf = bb.get('file')
        nb = bb.get('bones')
        if not bf or bf not in names:
            r.fail(f"角色 {cn}: bone_buffer.file={bf!r} 缺失"); continue
        cnt = frames * nb * 10
        off = bb.get('offset')
        if off is None:
            off = bone_running.get(bf, 0)
        bone_running[bf] = off + cnt
        need = (off + cnt) * F4
        if size_of(bf) < need:
            r.fail(f"角色 {cn}: bones.bin 需 {need}B（offset={off} 起 {cnt} floats）实际 {size_of(bf)}B")
        else:
            q = read_f4(bf, cnt, float_offset=off).reshape(-1, 10)[:, :4]
            qn = np.linalg.norm(q.astype(np.float64), axis=1)
            if np.any(np.abs(qn - 1) > 0.02):
                r.warn(f"角色 {cn}: 四元数未归一化（|q|∈[{qn.min():.3f},{qn.max():.3f}]）")
            else:
                r.ok(f"角色 {cn}: 骨骼 track 正常（{nb} 骨 × {frames} 帧，offset={off}，四元数归一化）")
        for part in c.get('parts') or []:
            for attr in ('bi', 'bw'):
                if attr not in (part.get('buf') or {}):
                    r.warn(f"角色 {cn} 部件 {part.get('name')}: 缺 buf.{attr}")

    # ---------- 可选块一致性 ----------
    for key, fkey, dim in (('particles', 'buffer', None), ('visibility', 'buffer', None),
                           ('debris', 'buffer', None), ('ao', 'buffer', None)):
        sec = pkg.get(key)
        if not sec: continue
        f = sec.get(fkey)
        if f and f not in names:
            r.fail(f"{key}: 声明了 buffer={f} 但文件缺失")
        elif f:
            r.ok(f"{key} 块存在（{f}）")
    if pkg.get('visibility'):
        vis = pkg['visibility']
        vg = vis.get('groups')
        if vg and groups and vg != len(groups):
            r.fail(f"visibility.groups={vg} 与 groups[] 数量 {len(groups)} 不一致")

    # ---------- 光照 ----------
    if not pkg.get('sun'):
        r.warn("缺少 sun 主光（场景将只有环境光，画面发灰）")
    lights = pkg.get('lights') or []
    if len(lights) > 16:
        r.fail(f"lights 数量 {len(lights)} > MAX_LIGHTS(16)（App 静默截断前 16 个）")
    elif lights:
        r.ok(f"lights {len(lights)} 个（≤16）")
    if not pkg.get('defaults'):
        r.warn("缺少 defaults 渲染参数（App 用内置默认值）")

    # ---------- v1 特征检测 ----------
    if 'meshes' in pkg or 'indices' in pkg:
        r.info("v1 特征: meshes.groups / indices 顶层段 —— 需 pack_package.py 转换为 v2")
    if 'animation' in pkg:
        r.info("animation 段为语义描述，App 不需要（渲染数据已逐帧烤入）")

    return r

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    path = sys.argv[1]
    verbose = '-v' in sys.argv
    r = validate(path, verbose)
    print(f"===== pipapkg 验证报告: {path} =====")
    icon = {'FAIL': '[FAIL]', 'WARN': '[WARN]', 'PASS': '[ ok ]', 'INFO': '[info]'}
    for lv, msg in r.items:
        if not verbose and lv == 'PASS' and len(r.items) > 12:
            continue
        print(f"{icon[lv]} {msg}")
    print("=" * 40)
    if r.fails:
        print(f"结论: 不可导入 —— {r.fails} 个 FAIL, {r.warns} 个 WARN")
        sys.exit(2)
    print(f"结论: 可导入 —— 0 FAIL, {r.warns} 个 WARN")
    sys.exit(0)

if __name__ == '__main__':
    main()
