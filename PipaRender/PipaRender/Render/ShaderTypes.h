//
//  ShaderTypes.h
//  PipaRender — Swift/Metal 共享类型
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

#define MAX_BONES 16
#define MAX_LIGHTS 16

// 顶点属性 slot
typedef enum {
    VertexAttributePosition = 0,
    VertexAttributeNormal   = 1,
    VertexAttributeUV       = 2,
    VertexAttributeBoneIndex = 3,
    VertexAttributeBoneWeight = 4,
    VertexAttributeCorner   = 5,   // 粒子模板顶点 corner
} VertexAttribute;

// 缓冲区 slot
typedef enum {
    BufferIndexMeshPosition   = 0,
    BufferIndexMeshNormal     = 1,
    BufferIndexMeshUV         = 2,
    BufferIndexMeshBoneIndex  = 3,
    BufferIndexMeshBoneWeight = 4,
    BufferIndexParticleInstance = 5,
    BufferIndexDebrisModel    = 7,   // 碎块 per-instance 模型矩阵
    BufferIndexModel          = 8,   // 当前 draw 的模型矩阵（per-draw setVertexBytes）
    BufferIndexUniforms       = 10,
    BufferIndexBones          = 11,
    BufferIndexLights         = 12,
    BufferIndexAOKernel       = 13,
} BufferIndex;

// 纹理 slot（各 pass 独立编号）
typedef enum {
    TextureIndexAlbedo = 0,
    TextureIndexSSAONoise = 2,   // SSAO pass 噪声贴图（其余 pass 的 slot 各自编号）
} TextureIndex;

// 全 pass 共享 uniform（每帧/每阴影级更新）
typedef struct {
    simd_float4x4 view;            // world -> view
    simd_float4x4 proj;            // view -> clip（Metal 深度 [0,1]）
    simd_float4x4 invView;         // view -> world
    simd_float4x4 lightMat[3];     // world -> light clip（Metal [0,1]）
    simd_float4   lightDir;        // 太阳方向（世界，xyz）
    simd_float4   lightColor;      // 太阳颜色 rgb + intensity
    simd_float4   skyColor;
    simd_float4   groundColor;
    simd_float4   ambient;         // x = intensity
    simd_float4   specRough;       // x = specStrength, y = roughness
    simd_float4   shadowParams;    // x = softness, y = texelSize, z = samples, w = enabled
    simd_float4   splits;          // 级联分割（view 深度）
    simd_float4   aoParams;        // x = radius, y = bias, z = intensity, w = enabled（采样数见 numLights.y）
    simd_float4   pointParams;     // x = pointScale, y = pointSoft
    simd_float4   exposureGamma;   // x = exposure, y = gamma
    simd_float4   tonemapMode;     // x = mode, y = hasBloom, z = hasGlare, w = bloomStrength
    simd_float4   glareStrength;   // x
    simd_float4   bloomThreshold;  // x
    simd_float4   glareThreshold;  // x = threshold, y = smoothness
    simd_float4   screen;          // x = width, y = height, z = 1/width, w = 1/height
    simd_float4   particleParams;  // x = width(px), y = scale, z = stretch, w = unused
    simd_float4   numLights;       // x = 灯光数, y = SSAO 采样数（借位）, z = 开启级联数, w = 未用
    simd_float4   flipMode;        // x = 输出上下翻转（视频编码开，预览关）
} Uniforms;

typedef struct {
    simd_float4 pos;       // 世界坐标
    simd_float4 col;       // 线性颜色
    simd_float4 dir;       // AREA 法线（世界）；w = kind（1=area, 0=point）
    simd_float4 energy;    // x = energy
} LightData;

#endif /* ShaderTypes_h */
