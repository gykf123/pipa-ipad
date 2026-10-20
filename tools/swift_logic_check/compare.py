#!/usr/bin/env python3
"""对比 Swift 输出与 numpy 独立复刻（验证 Swift 侧公式正确性）"""
import numpy as np, os, sys

D = '/tmp/swifttest'
fails = []

def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL"), name, detail)
    if not ok:
        fails.append(name)

# ---------- 1. boneMatrix ----------
lines = open(f'{D}/bone_input.txt').read().strip().split('\n')
arm = np.array([float(x) for x in lines[0].split(': ')[1].split(',')]).reshape(4, 4)
tracks = [np.array([float(x) for x in l.split(': ')[1].split(',')]) for l in lines[1:]]

BASIS = np.array([[1,0,0,0],[0,0,1,0],[0,-1,0,0],[0,0,0,1]], dtype=np.float64)
BI = np.linalg.inv(BASIS)

def quat_mat(x, y, z, w):
    n = x*x+y*y+z*z+w*w
    s = 2.0/n
    return np.array([
        [1-s*(y*y+z*z), s*(x*y-z*w),   s*(x*z+y*w),   0],
        [s*(x*y+z*w),   1-s*(x*x+z*z), s*(y*z-x*w),   0],
        [s*(x*z-y*w),   s*(y*z+x*w),   1-s*(x*x+y*y), 0],
        [0,0,0,1]], dtype=np.float64)

def T(t):
    m = np.eye(4); m[0,3], m[1,3], m[2,3] = t
    return m

swift_out = np.array([float(x) for x in open(f'{D}/bone_swift.txt').read().split()]).reshape(-1, 16)
max_err = 0.0
for b, tr in enumerate(tracks):
    q = tr[:4]; t = tr[4:7]; s = tr[7:10]
    R = quat_mat(*q)
    local = T(t) @ np.diag(np.concatenate([s, [1.0]])) @ R
    M = BASIS @ arm @ local @ BI
    err = np.abs(M.reshape(-1) - swift_out[b]).max()
    max_err = max(max_err, err)
check('boneMatrix', max_err < 1e-5, f'max_err={max_err:.3e}')

# ---------- 2. track 插值（slerp） ----------
interp = open(f'{D}/interp_swift.txt').read().strip()
q_sw = [float(x) for x in interp.split('q=')[1].split(' t=')[0].split(',')]
t_sw = [float(x) for x in interp.split('t=')[1].split(' s=')[0].split(',')]
s_sw = [float(x) for x in interp.split('s=')[1].split(',')]
a = np.array([0,0,0,1,0,0,0,1,1,1]); b2 = np.array([0.7071068,0,0,0.7071068,2,0,0,2,2,2])
qa, qb = a[:4], b2[:4]
dot = np.dot(qa, qb)
theta = np.arccos(np.clip(dot, -1, 1))
s0, s1 = np.sin((1-0.5)*theta), np.sin(0.5*theta)
q_np = (qa*s0 + qb*s1)/np.sin(theta)
t_np = a[4:7] + (b2[4:7]-a[4:7])*0.5
s_np = a[7:10] + (b2[7:10]-a[7:10])*0.5
err = max(np.abs(q_np - np.array(q_sw)).max(), np.abs(t_np-np.array(t_sw)).max(), np.abs(s_np-np.array(s_sw)).max())
check('interpTrack(slerp)', err < 1e-6, f'err={err:.3e}')

# ---------- 3. 投影矩阵 ----------
proj = open(f'{D}/proj_swift.txt').read().strip().split('\n')
ok = True
for l in proj:
    if l.startswith('zv='):
        zv = float(l.split('zv=')[1].split()[0])
        ndc = float(l.split('ndcZ=')[1].split()[0])
        back = float(l.split('back=')[1])
        # ndc 应在 [0,1]；反投影回 view 应等于 -zv（float32 伴随求逆，用相对误差）
        rel = abs(back + zv) / max(abs(zv), 1.0)
        if not (0.0 <= ndc <= 1.0 and rel < 2e-3):
            ok = False
    if l.startswith('ortho'):
        zv = float(l.split('zv=')[1].split()[0])
        ndc = float(l.split('ndcZ=')[1])
        # view -near -> 0, view -far -> 1
        exp = 0.0 if abs(zv + 0.01) < 1e-6 else (1.0 if abs(zv + 50.0) < 1e-6 else None)
        if exp is not None and abs(ndc - exp) > 1e-5:
            ok = False
check('perspective/ortho', ok, '\n    ' + '\n    '.join(proj))

# ---------- 4. 视锥剔除 ----------
fr = open(f'{D}/frustum_swift.txt').read().strip().split('\n')
expect = {'front-center': True, 'behind-camera': False, 'far-away': False,
          'far-plane-inside': True, 'off-fov-edge': False, 'straddling-near': True}
ok = True
for l in fr:
    name, val = l.split(': ')
    if (val == 'true') != expect[name]:
        ok = False
check('frustum', ok, '; '.join(fr))

# ---------- 5. 级联阴影 ----------
csm = open(f'{D}/csm_swift.txt').read().strip().split('\n')
ok = True
for l in csm:
    ndc = [float(x) for x in l.split('=')[1].split(',')]
    # 深度应在 [0,1]；xy 允许超出（点可在该级包围球外，由其它级负责，shader 有范围检查）
    if not (-0.001 <= ndc[2] <= 1.001 and abs(ndc[0]) < 50 and abs(ndc[1]) < 50):
        ok = False
check('cascadeMatrices', ok, '; '.join(csm))

# ---------- 6. 可见性位图 ----------
vis = open(f'{D}/vis_swift.txt').read().strip()
expect_vis = {'f0g0': True, 'f0g63': True, 'f0g64': True, 'f0g1': False, 'f1g1': True, 'f1g0': False}
ok = True
for kv in vis.split():
    k, v = kv.split('=')
    if (v == 'true') != expect_vis[k]:
        ok = False
check('visibilityBitmap', ok, vis)

# ---------- 7. 抽帧 ----------
st = open(f'{D}/settings_swift.txt').read().strip()
kv = dict(x.split('=') for x in st.split())
ok = (kv['count'] == '1865' and kv['f0'] == '0.0' and kv['f100'] == '200.0' and kv['fLast'] == '3728.0')
check('frameResample', ok, st)

print()
print('RESULT:', 'ALL PASS' if not fails else f'{len(fails)} FAILED: {fails}')
sys.exit(1 if fails else 0)
