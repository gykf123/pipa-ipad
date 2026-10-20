//
//  PipaShaders.metal
//  PipaRender — 琵琶曲渲染管线（MSL 移植自桌面端 GLSL，逐 pass 对照）
//
//  约定差异（相对 GL）：
//   - 深度范围 [0,1]（Metal 惯例），所有投影/正交矩阵由 Swift 端转好
//   - 点精灵/拖尾用 instanced 6 顶点 quad（Metal 无 gl_PointSize）
//   - gl_FrontFacing -> [[front_facing]]
//   - 输出视频帧需上下翻转（Metal 纹理左下原点 vs 视频左上原点），由 flipMode 控制
//

#include <metal_common>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

// ---------------------------------------------------------------- 公共

constant static const float BLUR_W[5] = {0.227027, 0.194595, 0.121622, 0.054054, 0.016216};
constant static const float PI = 3.14159265359;

float3 srgb_to_linear(float3 c) {
    return pow(c, 2.2);
}

// 全屏三角形（无顶点缓冲，vertex_id 生成）
struct FullscreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    FullscreenVertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = p;
    return out;
}

// ---------------------------------------------------------------- 网格 pass（G-buffer / shadow 共用顶点布局）

struct MeshVertexIn {
    float3 position  [[attribute(VertexAttributePosition)]];
    float3 normal    [[attribute(VertexAttributeNormal)]];
    float2 uv        [[attribute(VertexAttributeUV)]];
    float4 boneIdx   [[attribute(VertexAttributeBoneIndex)]];
    float4 boneW     [[attribute(VertexAttributeBoneWeight)]];
};

struct MeshVertexOut {
    float4 position  [[position]];
    float3 worldPos;
    float3 viewNormal;
    float3 viewPos;
    float2 uv;
};

vertex MeshVertexOut mesh_vertex(MeshVertexIn in [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]],
                                 constant float4x4 *bones [[buffer(BufferIndexBones)]],
                                 constant float4x4 *instModels [[buffer(BufferIndexDebrisModel)]],
                                 constant float4x4 &model [[buffer(BufferIndexModel)]],
                                 uint iid [[instance_id]],
                                 bool skinned [[function_constant]],
                                 bool useInstanceModel [[function_constant]]) {
    float4 local = float4(in.position, 1.0);
    float3 nrm = in.normal;
    if (skinned) {
        float4x4 skin = in.boneW.x * bones[int(in.boneIdx.x)]
                      + in.boneW.y * bones[int(in.boneIdx.y)]
                      + in.boneW.z * bones[int(in.boneIdx.z)]
                      + in.boneW.w * bones[int(in.boneIdx.w)];
        local = skin * local;
        nrm = float3x3(skin) * nrm;
    }
    // 碎块用 per-instance 模型矩阵（一次 instanced draw 画全部活碎块）
    float4x4 mdl = useInstanceModel ? instModels[iid] : model;
    float4 world = mdl * local;
    MeshVertexOut out;
    out.worldPos = world.xyz;
    out.uv = in.uv;
    float4 view = uniforms.view * world;
    out.viewPos = view.xyz;
    out.viewNormal = normalize(float3x3(uniforms.view) * float3x3(mdl) * nrm);
    out.position = uniforms.proj * view;
    return out;
}

// G-buffer：albedo(rgba8) / normal(rgba16F) / viewpos(rgba16F) / emit(rgba16F)
struct GBufferOut {
    float4 albedo  [[color(0)]];
    float4 normal  [[color(1)]];
    float4 viewpos [[color(2)]];
    float4 emit    [[color(3)]];
};

fragment GBufferOut mesh_fragment(MeshVertexOut in [[stage_in]],
                                  texture2d<float> albedoTex [[texture(TextureIndexAlbedo)]],
                                  sampler albedoSmp [[sampler(0)]],
                                  constant float4 &tint      [[buffer(14)]],
                                  constant float4 &emission  [[buffer(15)]],
                                  constant int &hasTex       [[buffer(16)]],
                                  bool front [[front_facing]]) {
    float3 n = normalize(in.viewNormal);
    if (!front) n = -n;   // 房间是单面平面（EEVEE 双面渲染），背面翻转法线
    float4 texel = float4(1.0);
    if (hasTex == 1) {
        texel = albedoTex.sample(albedoSmp, in.uv);
    }
    float4 c = texel * tint;
    GBufferOut out;
    out.albedo  = float4(srgb_to_linear(c.rgb), 1.0);
    out.normal  = float4(n, 1.0);
    out.viewpos = float4(in.viewPos, 1.0);
    out.emit    = float4(emission.rgb * c.a, 1.0);
    return out;
}

// G-buffer（镂空变体）：alpha < 0.5 discard
fragment GBufferOut mesh_fragment_cut(MeshVertexOut in [[stage_in]],
                                      texture2d<float> albedoTex [[texture(TextureIndexAlbedo)]],
                                      sampler albedoSmp [[sampler(0)]],
                                      constant float4 &tint      [[buffer(14)]],
                                      constant float4 &emission  [[buffer(15)]],
                                      constant int &hasTex       [[buffer(16)]],
                                      bool front [[front_facing]]) {
    float3 n = normalize(in.viewNormal);
    if (!front) n = -n;
    float4 texel = float4(1.0);
    if (hasTex == 1) {
        texel = albedoTex.sample(albedoSmp, in.uv);
    }
    float4 c = texel * tint;
    if (c.a < 0.5) discard_fragment();
    GBufferOut out;
    out.albedo  = float4(srgb_to_linear(c.rgb), 1.0);
    out.normal  = float4(n, 1.0);
    out.viewpos = float4(in.viewPos, 1.0);
    out.emit    = float4(emission.rgb * c.a, 1.0);
    return out;
}

// 阴影深度 pass（镂空变体：贴图 alpha < 0.5 处不打洞）
fragment void shadow_fragment_cut(MeshVertexOut in [[stage_in]],
                                  texture2d<float> albedoTex [[texture(TextureIndexAlbedo)]],
                                  sampler albedoSmp [[sampler(0)]],
                                  constant int &hasTex [[buffer(16)]]) {
    if (hasTex == 1 && albedoTex.sample(albedoSmp, in.uv).a < 0.5) {
        discard_fragment();
    }
}

fragment void shadow_fragment(MeshVertexOut in [[stage_in]]) {
    // 不镂空：只写深度
}

// ---------------------------------------------------------------- SSAO

fragment float ssao_fragment(FullscreenVertexOut in [[stage_in]],
                             constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]],
                             constant float3 *kernel [[buffer(BufferIndexAOKernel)]],
                             texture2d<float> viewposTex [[texture(0)]],
                             texture2d<float> normalTex  [[texture(1)]],
                             texture2d<float> noiseTex   [[texture(2)]],
                             sampler screenSmp [[sampler(0)]],
                             sampler noiseSmp  [[sampler(1)]]) {
    float4 vp = viewposTex.sample(screenSmp, in.uv);
    if (vp.w < 0.5) return 1.0;
    float3 P = vp.xyz;
    float3 N = normalize(normalTex.sample(screenSmp, in.uv).xyz);

    float3 rvec = noiseTex.sample(noiseSmp, in.uv * (uniforms.screen.xy / 4.0)).xyz * 2.0 - 1.0;
    float3 tangent = normalize(rvec - N * dot(rvec, N));
    float3 bitangent = cross(N, tangent);
    float3x3 tbn = float3x3(tangent, bitangent, N);

    float occ = 0.0;
    int count = 0;
    int samples = int(uniforms.numLights.y);   // AO 采样数借位
    float radius = uniforms.aoParams.x;
    float bias = uniforms.aoParams.y;
    for (int i = 0; i < 64; ++i) {
        if (i >= samples) break;
        count++;
        float3 sp = tbn * kernel[i] * radius + P;
        float4 off = uniforms.proj * float4(sp, 1.0);
        if (off.w <= 0.0) continue;
        float3 ndc = off.xyz / off.w;
        float2 suv = ndc.xy * 0.5 + 0.5;
        if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;
        float4 spv = viewposTex.sample(screenSmp, suv);
        if (spv.w < 0.5) continue;
        float range = smoothstep(0.0, 1.0, radius / max(abs(P.z - spv.z), 1e-5));
        occ += (spv.z >= sp.z + bias ? 1.0 : 0.0) * range;
    }
    float ao = 1.0 - (occ / max(float(count), 1.0)) * uniforms.aoParams.z;
    return clamp(ao, 0.0, 1.0);
}

// ---------------------------------------------------------------- 通用可分离高斯模糊

fragment float4 blur_fragment(FullscreenVertexOut in [[stage_in]],
                              texture2d<float> srcTex [[texture(0)]],
                              sampler smp [[sampler(0)]],
                              constant float2 &dir [[buffer(14)]]) {
    float4 acc = srcTex.sample(smp, in.uv) * BLUR_W[0];
    for (int i = 1; i < 5; ++i) {
        float2 o = dir * float(i);
        acc += srcTex.sample(smp, in.uv + o) * BLUR_W[i];
        acc += srcTex.sample(smp, in.uv - o) * BLUR_W[i];
    }
    return acc;
}

// ---------------------------------------------------------------- 延迟光照

fragment float4 lighting_fragment(FullscreenVertexOut in [[stage_in]],
                                  constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]],
                                  constant LightData *lights [[buffer(BufferIndexLights)]],
                                  texture2d<float> albedoTex  [[texture(0)]],
                                  texture2d<float> normalTex  [[texture(1)]],
                                  texture2d<float> viewposTex [[texture(2)]],
                                  texture2d<float> emitTex    [[texture(3)]],
                                  texture2d<float> aoTex      [[texture(4)]],
                                  texture2d<float> shadow0    [[texture(5)]],
                                  texture2d<float> shadow1    [[texture(6)]],
                                  texture2d<float> shadow2    [[texture(7)]],
                                  sampler smp [[sampler(0)]]) {
    float4 vp = viewposTex.sample(smp, in.uv);
    float3 albedo = albedoTex.sample(smp, in.uv).rgb;
    float3 emit = emitTex.sample(smp, in.uv).rgb;

    if (vp.w < 0.5) {
        float3 sky = mix(uniforms.groundColor.rgb, uniforms.skyColor.rgb, 0.55) * uniforms.ambient.x;
        return float4(sky, 1.0);
    }

    float3 N = normalize(normalTex.sample(smp, in.uv).xyz);      // view space
    float3 Nw = normalize(float3x3(uniforms.invView) * N);        // world
    float3 P = (uniforms.invView * float4(vp.xyz, 1.0)).xyz;
    float viewdepth = -vp.z;

    float3 L = normalize(uniforms.lightDir.xyz);
    float3 V = normalize(uniforms.invView[3].xyz - P);
    float3 H = normalize(L + V);
    float ndl = max(dot(Nw, L), 0.0);
    float ndh = max(dot(Nw, H), 0.0);
    float ndv = max(dot(Nw, V), 1e-4);

    float a = max(uniforms.specRough.y * uniforms.specRough.y, 1e-4);
    float a2 = a * a;
    float den = ndh * ndh * (a2 - 1.0) + 1.0;
    float D = a2 / (PI * den * den);
    float k = a * 0.5;
    float G = (ndl / (ndl * (1.0 - k) + k)) * (ndv / (ndv * (1.0 - k) + k));
    float3 F0 = float3(0.05);
    float3 F = F0 + (1.0 - F0) * pow(1.0 - max(dot(H, V), 0.0), 5.0);
    float spec = (D * G) * (F.r) / (4.0 * ndl * ndv + 1e-4) * ndl;

    float shadow = 1.0;
    if (uniforms.shadowParams.w > 0.5) {
        int ci = 0;
        if (viewdepth > uniforms.splits.x) ci = 1;
        if (viewdepth > uniforms.splits.y) ci = 2;

        float4 lp = uniforms.lightMat[ci] * float4(P, 1.0);
        float3 pc = lp.xyz / lp.w;
        pc.xy = pc.xy * 0.5 + 0.5;    // z 已是 [0,1]（Metal 矩阵）
        float radius = uniforms.shadowParams.x * uniforms.shadowParams.y;

        float bias = max(0.0020 * (1.0 - ndl), 0.0006);
        if (pc.z <= 1.0 && pc.x > 0.0 && pc.x < 1.0 && pc.y > 0.0 && pc.y < 1.0) {
            int samples = int(uniforms.shadowParams.z);
            float s = 0.0;
            for (int i = 0; i < 32; ++i) {
                if (i >= samples) break;
                float ang = float(i) * 2.39996323;
                float rr = sqrt((float(i) + 0.5) / float(samples));
                float2 o = float2(cos(ang), sin(ang)) * rr * radius;
                float d = (ci == 0 ? shadow0 : (ci == 1 ? shadow1 : shadow2)).sample(smp, pc.xy + o).r;
                s += (pc.z - bias > d) ? 0.0 : 1.0;
            }
            shadow = s / float(samples);
        }
    }

    float ao = 1.0;
    if (uniforms.aoParams.w > 0.5) {   // AO 开启
        ao = aoTex.sample(smp, in.uv).r;
    }

    float3 diffuse = albedo / PI * uniforms.lightColor.rgb * uniforms.lightColor.w * ndl * shadow;
    float3 specular = uniforms.lightColor.rgb * uniforms.lightColor.w * spec * shadow * uniforms.specRough.x;

    // 烘焙点光/面光：平方衰减，世界空间逐像素计算
    float3 point = float3(0.0);
    float soft2 = uniforms.pointParams.y * uniforms.pointParams.y;
    int n = int(uniforms.numLights.x);
    for (int i = 0; i < MAX_LIGHTS; ++i) {
        if (i >= n) break;
        float3 d = lights[i].pos.xyz - P;
        float dist2 = max(dot(d, d), 1e-3);
        float3 Lp = d * rsqrt(dist2);
        float nl = max(dot(Nw, Lp), 0.0);

        float panel = 1.0;
        if (lights[i].dir.w > 0.5) {          // AREA 单侧面光
            panel = max(dot(-Lp, lights[i].dir.xyz), 0.0);
            if (panel <= 0.0) continue;
        }

        float atten = lights[i].energy.x / (4.0 * PI * (dist2 + soft2));
        point += lights[i].col.rgb * (albedo / PI * nl * panel * atten * uniforms.pointParams.x);
    }

    float up = Nw.y * 0.5 + 0.5;
    float3 ambient = albedo * mix(uniforms.groundColor.rgb, uniforms.skyColor.rgb, up)
                     * uniforms.ambient.x * ao;

    return float4(diffuse + specular + point + ambient + emit, 1.0);
}

// ---------------------------------------------------------------- 泛光 / 辉光 / tonemap

fragment float4 bright_fragment(FullscreenVertexOut in [[stage_in]],
                                texture2d<float> hdrTex [[texture(0)]],
                                sampler smp [[sampler(0)]],
                                constant float4 &threshold  [[buffer(14)]],
                                constant float4 &smoothness [[buffer(15)]]) {
    float3 c = hdrTex.sample(smp, in.uv).rgb;
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    float f;
    if (smoothness.x <= 0.0) {
        f = max(l - threshold.x, 0.0) / max(l, 1e-4);
    } else {
        float lo = threshold.x * max(1.0 - smoothness.x, 0.0);
        f = clamp((l - lo) / max(threshold.x - lo, 1e-4), 0.0, 1.0);
    }
    return float4(c * f, 1.0);
}

float3 aces(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

float3 uncharted2(float3 x) {
    const float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

float3 filmic(float3 x) {
    float3 white = uncharted2(float3(11.2));
    return clamp(uncharted2(x * 2.0) / white, 0.0, 1.0);
}

fragment float4 tonemap_fragment(FullscreenVertexOut in [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]],
                                 texture2d<float> hdrTex   [[texture(0)]],
                                 texture2d<float> bloomTex [[texture(1)]],
                                 texture2d<float> glareTex [[texture(2)]],
                                 sampler smp [[sampler(0)]]) {
    // 视频编码时上下翻转（Metal 纹理左下原点 -> 视频左上原点）
    float2 suv = uniforms.flipMode.x > 0.5 ? float2(in.uv.x, 1.0 - in.uv.y) : in.uv;

    float3 c = hdrTex.sample(smp, suv).rgb;

    if (uniforms.tonemapMode.y > 0.5) {
        c += bloomTex.sample(smp, suv).rgb * uniforms.tonemapMode.w;
    }
    if (uniforms.tonemapMode.z > 0.5) {
        c += glareTex.sample(smp, suv).rgb * uniforms.glareStrength.x;
    }

    c *= uniforms.exposureGamma.x;

    int mode = int(uniforms.tonemapMode.x);
    if (mode == 0) {
        c = filmic(c);
    } else if (mode == 1) {
        c = aces(c);
    } else {
        c = clamp(c, 0.0, 1.0);
    }

    c = pow(max(c, 0.0), float3(1.0 / uniforms.exposureGamma.y));
    return float4(c, 1.0);
}

// ---------------------------------------------------------------- 粒子（instanced quad）

// 拖尾四边形：6 模板顶点（corner.x = 横向 ±1，corner.y = 沿向 0/1）
struct TracerTemplate {
    float2 corner [[attribute(VertexAttributeCorner)]];
};

struct TracerInstance {
    float3 pos;     // 世界位置（快门中心）
    float3 half;    // 半程偏移（= vel * shutter * 0.5）
    float3 em;      // 线性自发光
};

struct TracerVertexOut {
    float4 position [[position]];
    float2 corner;
    float3 em;
};

vertex TracerVertexOut tracer_vertex(TracerTemplate in [[stage_in]],
                                     constant TracerInstance *instances [[buffer(BufferIndexParticleInstance)]],
                                     constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]],
                                     uint iid [[instance_id]]) {
    TracerInstance inst = instances[iid];
    float stretch = uniforms.particleParams.z;
    float3 p = inst.pos + inst.half * (stretch * (in.corner.y * 2.0 - 1.0));
    float4 clip = uniforms.proj * uniforms.view * float4(p, 1.0);

    float4 ca = uniforms.proj * uniforms.view * float4(inst.pos - inst.half * stretch, 1.0);
    float4 cb = uniforms.proj * uniforms.view * float4(inst.pos + inst.half * stretch, 1.0);
    float2 dir = cb.xy / max(abs(cb.w), 1e-6) - ca.xy / max(abs(ca.w), 1e-6);
    dir = (dot(dir, dir) < 1e-12) ? float2(1.0, 0.0) : normalize(dir);

    clip.xy += float2(-dir.y, dir.x) * (in.corner.x * uniforms.particleParams.x * 2.0 / uniforms.screen.y) * clip.w;

    TracerVertexOut out;
    out.position = clip;
    out.corner = in.corner;
    out.em = inst.em;
    return out;
}

fragment float4 tracer_fragment(TracerVertexOut in [[stage_in]],
                                constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]]) {
    float across = sqrt(max(0.0, 1.0 - in.corner.x * in.corner.x));
    float along = smoothstep(0.0, 0.3, in.corner.y) * smoothstep(1.0, 0.7, in.corner.y);
    return float4(in.em * abs(uniforms.particleParams.y) * across * along, 1.0);
}

// 点精灵：6 模板顶点（NDC 方形 corner ∈ [-1,1]）
struct PointTemplate {
    float2 corner [[attribute(VertexAttributeCorner)]];
};

struct PointInstance {
    float3 pos;
    float size;
    float3 em;
};

struct PointVertexOut {
    float4 position [[position]];
    float2 corner;
    float3 em;
};

vertex PointVertexOut point_vertex(PointTemplate in [[stage_in]],
                                   constant PointInstance *instances [[buffer(BufferIndexParticleInstance)]],
                                   constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]],
                                   uint iid [[instance_id]]) {
    PointInstance inst = instances[iid];
    float4 vp = uniforms.view * float4(inst.pos, 1.0);
    float4 clip = uniforms.proj * vp;

    float z = max(-vp.z, 0.05);
    float pointSize = clamp(inst.size * uniforms.proj[1][1] * uniforms.screen.y / z, 2.0, 96.0);
    // 直径 pointSize 像素 -> NDC 半宽 = pointSize / screen.y（NDC y 跨度 2 = screen.y 像素）
    clip.xy += in.corner * (pointSize / uniforms.screen.y) * clip.w;

    PointVertexOut out;
    out.position = clip;
    out.corner = in.corner;
    out.em = inst.em;
    return out;
}

fragment float4 point_fragment(PointVertexOut in [[stage_in]],
                               constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]]) {
    float r2 = dot(in.corner, in.corner);
    if (r2 > 1.0) discard_fragment();
    float fall = exp(-2.6 * r2);
    return float4(in.em * fall * abs(uniforms.particleParams.y), 1.0);
}
