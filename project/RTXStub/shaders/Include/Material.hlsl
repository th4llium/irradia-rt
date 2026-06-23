/* MIT License
 * 
 * Copyright (c) 2025 veka0
 * Copyright (c) 2026 th4llium
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#ifndef __MATERIAL_HLSL__
#define __MATERIAL_HLSL__

#include "Generated/Signature.hlsl"
#include "Constants.hlsl"
#include "Util.hlsl"

struct HitInfo
{
    float rayT;
    bool frontFacing;
    float2 barycentric2;
    uint materialType; // See MATERIAL_TYPE macros in Constants.hlsl
    uint objectInstanceIndex;
    uint primitiveId;
};

HitInfo GetCommittedHitInfo(RayQuery<RAY_FLAG_NONE> q)
{
    HitInfo hitInfo;
    hitInfo.rayT = q.CommittedRayT();
    hitInfo.frontFacing = q.CommittedTriangleFrontFace();
    hitInfo.barycentric2 = q.CommittedTriangleBarycentrics();
    hitInfo.materialType = q.CommittedInstanceID();
    hitInfo.objectInstanceIndex = q.CommittedInstanceIndex();
    hitInfo.primitiveId = q.CommittedPrimitiveIndex();
    return hitInfo;
}

HitInfo GetCandidateHitInfo(RayQuery<RAY_FLAG_NONE> q)
{
    HitInfo hitInfo;
    hitInfo.rayT = q.CandidateTriangleRayT();
    hitInfo.frontFacing = q.CandidateTriangleFrontFace();
    hitInfo.barycentric2 = q.CandidateTriangleBarycentrics();
    hitInfo.materialType = q.CandidateInstanceID();
    hitInfo.objectInstanceIndex = q.CandidateInstanceIndex();
    hitInfo.primitiveId = q.CandidatePrimitiveIndex();
    return hitInfo;
}



struct GeometryInfo
{
    float3 barycentric;
    float uvAreaPerWorldArea;

    // TBN
    float3 tangent;
    float3 bitangent;
    float3 geometryNormal;

    // Vertex attributes
    float3 position;
    float3 vertexNormal; // May be invalid for certain objects, check if normalByteOffset is not 0
    float4 color;
    float2 uv0;
    // float2 uv1;
    // float2 uv2;
    // float2 uv3;
    uint pbrTextureDataIndex; // Optional, equals to kInvalidPBRTextureHandle if inapplicable.
    float3 previousPosition; // Optional, equals to 0 by default. Check for kObjectInstanceFlagHasMotionVectors flag to see if it's applicable.
};

GeometryInfo GetGeometryInfo(HitInfo hitInfo, ObjectInstance objectInstance) {
    GeometryInfo geometryInfo;

    uint positionByteOffset = objectInstance.offsetPack1 & 0xff;
    uint normalByteOffset = objectInstance.offsetPack1 >> 8;
    uint colorByteOffset = objectInstance.offsetPack2 & 0xff;
    uint uv0ByteOffset = objectInstance.offsetPack2 >> 8;
    uint uv1ByteOffset = objectInstance.offsetPack3 & 0xff;
    uint uv2ByteOffset = objectInstance.offsetPack3 >> 8;
    uint uv3ByteOffset = objectInstance.offsetPack4 & 0xff;
    uint PBRTextureIdByteOffset = objectInstance.offsetPack4 >> 8;
    uint previousPositionOffset = objectInstance.offsetPack5 & 0xff;
    uint mediaType = objectInstance.offsetPack5 >> 8; // See MEDIA_TYPE macros in Constants.hlsl

    ByteAddressBuffer vertexBuffer = vertexBuffers[objectInstance.vbIdx];

    uint firstVertexOffsetInQuad = (hitInfo.primitiveId / 2) * 4;
    uint3 vertices = firstVertexOffsetInQuad + (hitInfo.primitiveId & 1 ? uint3(2, 3, 0) : uint3(0, 1, 2)); // Choose 3 vertices based on whether this is the first or second triangle in the quad.
    geometryInfo.barycentric = float3(1 - hitInfo.barycentric2.x - hitInfo.barycentric2.y, hitInfo.barycentric2.xy);

    float2 uvs[3];
    float3 positions[3];
    geometryInfo.uv0 = 0..xx;
    geometryInfo.color = 0..xxxx;
    geometryInfo.position = 0..xxx;
    geometryInfo.previousPosition = 0..xxx;
    geometryInfo.vertexNormal = 0..xxx;
    geometryInfo.uvAreaPerWorldArea = 0.0;

    [unroll]
    for (uint i = 0; i < 3; ++i)
    {
        // Parallel buffers use vertexOffsetInParallelVertices.
        uint address = (vertices[i] + objectInstance.vertexOffsetInBaseVertices) * objectInstance.vertexStride;
   
        positions[i] = vertexBuffer.Load<float16_t4>(address + positionByteOffset).xyz;
        geometryInfo.position += geometryInfo.barycentric[i] * positions[i];

        if (objectInstance.flags & kObjectInstanceFlagHasMotionVectors)
        {
            geometryInfo.previousPosition += geometryInfo.barycentric[i] * vertexBuffer.Load<float16_t4>(address + previousPositionOffset).xyz;
        }

        geometryInfo.color += geometryInfo.barycentric[i] * unpackVertexColor(vertexBuffer.Load(address + colorByteOffset));
        geometryInfo.vertexNormal += geometryInfo.barycentric[i] * unpackNormal(vertexBuffer.Load(address + normalByteOffset)).xyz;
        uvs[i] = unpackVertexUV(vertexBuffer.Load(address + uv0ByteOffset), objectInstance.flags & kObjectInstanceFlagUsesUvBiasPacking);
        geometryInfo.uv0 += geometryInfo.barycentric[i] * uvs[i];
    }

    // Catch cases where vertex color is not provided (block breaking overlay).
    if (!colorByteOffset) geometryInfo.color = 1;

    geometryInfo.geometryNormal = safeNormalize(cross((positions[1] - positions[0]), (positions[2] - positions[0])), float3(0, 1, 0));
    // vertexNormal = normalize(vertexNormal); // Vertex normal is not normalized as GeometryInfo is meant to pass raw attribute values.

    // Solve the tangent frame from position and UV gradients:

    // |T.x, B.x|                                |v1.x-v0.x, v2.x-v0.x|
    // |T.y, B.y| * |uv1.x-uv0.x, uv2.x-uv0.x| = |v1.y-v0.y, v2.y-v0.y|
    // |T.z, B.z|   |uv1.y-uv0.y, uv2.y-uv0.y|   |v1.z-v0.z, v2.z-v0.z|

    float2 dUV1 = uvs[1] - uvs[0];
    float2 dUV2 = uvs[2] - uvs[0];
    float3 dPos1 = positions[1] - positions[0];
    float3 dPos2 = positions[2] - positions[0];

    float det = determinant(float2x2(dUV1, dUV2));
    float3 worldDPos1 = mul(dPos1, (float3x3)objectInstance.modelToWorld);
    float3 worldDPos2 = mul(dPos2, (float3x3)objectInstance.modelToWorld);
    float worldArea = length(cross(worldDPos1, worldDPos2));
    geometryInfo.uvAreaPerWorldArea = abs(det) / max(worldArea, 1.0e-8);

    if (det == 0.0)
    {
        // Degenerate UVs need an arbitrary tangent frame.
        float3 helperVec = abs(dot(float3(0, 1, 0), geometryInfo.geometryNormal)) > 0.99 ? float3(1, 0, 0) : float3(0, 1, 0);

        geometryInfo.tangent = cross(geometryInfo.geometryNormal, helperVec);
        geometryInfo.bitangent = cross(geometryInfo.geometryNormal, geometryInfo.tangent);
    }
    else
    {
        det = det < 0 ? -1 : 1;

        dUV1 *= det;
        dUV2 *= det;

        geometryInfo.tangent = dUV2.y * dPos1 - dUV1.y * dPos2;
        geometryInfo.bitangent = dUV1.x * dPos2 - dUV2.x * dPos1;
    }
    geometryInfo.tangent = safeNormalize(geometryInfo.tangent, float3(1, 0, 0));
    geometryInfo.bitangent = safeNormalize(geometryInfo.bitangent, cross(geometryInfo.geometryNormal, geometryInfo.tangent));

    geometryInfo.pbrTextureDataIndex = PBRTextureIdByteOffset ? 
        vertexBuffer.Load<uint>((vertices[0] + objectInstance.vertexOffsetInBaseVertices) * objectInstance.vertexStride + PBRTextureIdByteOffset)
         : kInvalidPBRTextureHandle;

    return geometryInfo;
}

struct SurfaceInfo
{
    float3 color;
    float alpha;
    bool shouldDiscard;

    float3 position;
    float3 prevPosition;

    float metalness;
    float emissive;
    float roughness;
    float subsurface;

    float3 normal;

    void Init()
    {
        color = 0;
        alpha = 0;
        shouldDiscard = false;

        position = 0;
        prevPosition = 0;

        metalness = 0;
        emissive = 0;
        roughness = 1;
        subsurface = 0;

        normal = 0;
    }
};

// Shared actor material evaluation.
void EvaluateActorMaterial(ObjectInstance objectInstance, HitInfo hitInfo, float2 uv, float4 tintColor0, float4 tintColor1, inout float4 color, inout bool shouldDiscard) {
    // List of materials, in priority order
    const uint kMaterialActorGlint        = (1 << 0);
    const uint kMaterialActorMultiTexture = (1 << 1);
    const uint kMaterialActorTint         = (1 << 2);
    const uint kMaterialActor             = (1 << 3);

    uint actorMaterial;
    if (objectInstance.flags & kObjectInstanceFlagGlint) {
        actorMaterial = kMaterialActorGlint;
    } else if (objectInstance.flags & kObjectInstanceFlagMultiTexture) {
        actorMaterial = kMaterialActorMultiTexture;
    } else if ((objectInstance.flags & kObjectInstanceFlagMultiplicativeTint) && !(objectInstance.flags & kObjectInstanceFlagUsesOverlayColor)) {
        // Overlay color takes precedence over multiplicative tint.
        actorMaterial = kMaterialActorTint;
    } else {
        actorMaterial = kMaterialActor;
    }

    float4 tex1;
    if (objectInstance.secondaryTextureIdx != 0xffff)
    {
        tex1 = textures[objectInstance.secondaryTextureIdx].SampleLevel(pointSampler, uv, 0);

        // MASKED_MULTITEXTURE
        if (objectInstance.flags & kObjectInstanceFlagMaskedMultiTexture)
        {
            bool maskedTexture = (tex1.r + tex1.g + tex1.b) * (1.0 - tex1.a) > 0.0;
            color = maskedTexture ? color : tex1;
        }
    }

    // applyChangeColor()
    if (hitInfo.materialType != MATERIAL_TYPE_ALPHA_TEST || (actorMaterial & (kMaterialActorMultiTexture | kMaterialActorTint)))
    {
        // CHANGE_COLOR__MULTI is not used by vanilla actor materials.
        color.rgb *= lerp(1..xxx, tintColor0.rgb, color.a);
        color.a *= tintColor0.a;
    }

    float alpha = color.a;
    if (objectInstance.secondaryTextureIdx != 0xffff)
    {
        // applySecondColorTint()
        if ((actorMaterial & kMaterialActorTint) && hitInfo.materialType != MATERIAL_TYPE_ALPHA_BLEND)
        {
            alpha = tex1.a;
            color.rgb = lerp(color.rgb, tintColor1.rgb * tex1.rgb, tex1.a);
        }

        // MULTI_TEXTURE
        if (objectInstance.tertiaryTextureIdx != 0xffff && (actorMaterial & kMaterialActorMultiTexture))
        {
            // applyMultitextureAlbedo()
            float4 tex2 = textures[objectInstance.tertiaryTextureIdx].SampleLevel(pointSampler, uv, 0);

            alpha = tex1.a;
            color.rgb = lerp(color.rgb, tex1.rgb, tex1.a);

            color.rgb = lerp(color.rgb, tex2.rgb * tintColor0.rgb, tex2.a);
        }
    }

    // ALPHA_TEST
    const float actorAlphaEpsilon = 1e-5;
    if (hitInfo.materialType == MATERIAL_TYPE_ALPHA_TEST)
    {
        if (actorMaterial & kMaterialActorTint)
        {
            shouldDiscard = (color.a + alpha) < actorAlphaEpsilon;
        }
        else if (actorMaterial & kMaterialActorMultiTexture)
        {
            shouldDiscard =
                color.a < 0.5 && alpha <= actorAlphaEpsilon;
        }
        else
        {
            shouldDiscard = alpha < actorAlphaEpsilon;
        }

        // applyChangeColor()
        if (actorMaterial & (kMaterialActorGlint | kMaterialActor))
        {
            // CHANGE_COLOR__MULTI is not used by vanilla actor materials.
            color.rgb *= lerp(1..xxx, tintColor0.rgb, color.a);
            color.a *= tintColor0.a;
        }
    }
}

float CalculateRayConeTextureLod(
    GeometryInfo geometryInfo,
    float3 worldGeometryNormal,
    float3 rayDirection,
    float rayConeRadius,
    Texture2D<float4> texture)
{
    if (rayConeRadius <= 0.0 || geometryInfo.uvAreaPerWorldArea <= 0.0)
        return 0.0;

    uint textureWidth;
    uint textureHeight;
    uint textureMipCount;
    texture.GetDimensions(0, textureWidth, textureHeight, textureMipCount);

    float texelsPerWorldUnit = sqrt(
        max(geometryInfo.uvAreaPerWorldArea * (float)textureWidth * (float)textureHeight, 1.0e-8));

    // Clamp the projected footprint at grazing angles.
    float projectionCosine = max(abs(dot(rayDirection, worldGeometryNormal)), 0.1);
    float footprintInTexels = (2.0 * rayConeRadius * texelsPerWorldUnit) / projectionCosine;
    float lod = log2(max(footprintInTexels, 1.0)) + g_view.mipmapBias;

    return clamp(lod, 0.0, max((float)textureMipCount - 1.0, 0.0));
}

float TransformTextureLod(float baseLod, float2 uvScale, float maxMip)
{
    float scale = max(max(abs(uvScale.x), abs(uvScale.y)), 1.0e-4);
    return clamp(baseLod + log2(scale), 0.0, max(maxMip, 0.0));
}

SurfaceInfo MaterialVanilla(
    HitInfo hitInfo,
    GeometryInfo geometryInfo,
    ObjectInstance objectInstance,
    float rayConeRadius,
    float3 rayDirection)
{
    SurfaceInfo surfaceInfo;
    surfaceInfo.Init();

    uint normalByteOffset = objectInstance.offsetPack1 >> 8;
    float3 modelSpaceNormal = normalByteOffset ? geometryInfo.vertexNormal : geometryInfo.geometryNormal;
    surfaceInfo.normal = safeNormalize(mul(modelSpaceNormal, (float3x3)objectInstance.modelToWorld), float3(0, 1, 0));

    surfaceInfo.position = mul(float4(geometryInfo.position, 1), objectInstance.modelToWorld);
    surfaceInfo.prevPosition = mul(float4((objectInstance.flags & kObjectInstanceFlagHasMotionVectors) ? geometryInfo.previousPosition : geometryInfo.position, 1), objectInstance.prevModelToWorld);

    float4 color = 1..xxxx;
    float4 vertColor = geometryInfo.color;
    float2 uv = geometryInfo.uv0;

    bool isBanner = objectInstance.flags & kObjectInstanceFlagTextureAlphaControlsVertexColor && hitInfo.materialType == MATERIAL_TYPE_OPAQUE;

    Texture2D<float4> colorTex = textures[objectInstance.colourTextureIdx != 0xffff ? objectInstance.colourTextureIdx : g_view.missingTextureIndex];
    float3 worldGeometryNormal = safeNormalize(
        mul(geometryInfo.geometryNormal, (float3x3)objectInstance.modelToWorld),
        surfaceInfo.normal);
    float textureLod = CalculateRayConeTextureLod(
        geometryInfo, worldGeometryNormal, rayDirection, rayConeRadius, colorTex);
    bool useRayConeLod = rayConeRadius > 0.0;

    if (objectInstance.colourTextureIdx != 0xffff)
    {
        // Banner UV fix
        if (isBanner)
        {
            float2 size;
            colorTex.GetDimensions(size.x, size.y);
            uv += 1.0 / size;
        }
        color = colorTex.SampleLevel(pointSampler, uv, textureLod);
    }
    
    // Terrain uses the half-alpha threshold without setting the actor flag.
    surfaceInfo.shouldDiscard = hitInfo.materialType == MATERIAL_TYPE_ALPHA_TEST 
        && (objectInstance.flags & (kObjectInstanceFlagAlphaTestThresholdHalf | kObjectInstanceFlagChunk) ? color.a < 0.5 : color.a == 0.0);

    if (objectInstance.flags & kObjectInstanceFlagHasSeasonsTexture)
    {
        Texture2D seasonsTexture = textures[objectInstance.secondaryTextureIdx];

        vertColor.rgb = lerp(1..xxx, seasonsTexture.SampleLevel(pointSampler, vertColor.xy, 0).rgb * 2.0, vertColor.z);
        vertColor.rgb *= vertColor.a;
        color.a = 1.0; // In vanilla RenderChunk this only applies to opaque and alpha test passes
    }
    else
    {
        // Some held items (bow, crossbow) have identical texture and vertex colors.
        // Reset vertex color if that's the case, to avoid accidentally squaring albedo.
        if (all(abs(color - vertColor) < 0.001)) vertColor = 1;
    }

    if (isBanner)
    {
        // Banner vertices may arrive with zero color.
        vertColor.rgb = lerp(vertColor.rgb, 1.xxx, color.a);
    }

    // Remove baked directional shading from terrain vertex color.
    bool isTintShadedSurface = objectInstance.flags & (kObjectInstanceFlagChunk | kObjectInstanceFlagClouds) 
        && !(objectInstance.flags & kObjectInstanceFlagHasSeasonsTexture) 
        && vertColor.r == vertColor.g 
        && vertColor.g == vertColor.b
        && vertColor.a >= 0.999;

    if (isTintShadedSurface) vertColor.rgb = 1;

    color.rgb *= vertColor.rgb;
    if (objectInstance.flags & kObjectInstanceFlagChunk) color.a *= vertColor.a;

    // ChangeColor
    float4 tintColor0 = unpackObjectInstanceTintColor(objectInstance.tintColour0);
    // OverlayColor or MultiplicativeTintColor
    float4 tintColor1 = unpackObjectInstanceTintColor(objectInstance.tintColour1);

    const bool isActor = (
        objectInstance.flags & 
        (
            kObjectInstanceFlagHasMotionVectors | 
            kObjectInstanceFlagMaskedMultiTexture | 
            kObjectInstanceFlagMultiTexture | 
            kObjectInstanceFlagMultiplicativeTint | 
            kObjectInstanceFlagUsesOverlayColor | 
            kObjectInstanceFlagGlint
        ) && !(objectInstance.flags & (
            kObjectInstanceFlagHasSeasonsTexture | 
            kObjectInstanceFlagClouds | 
            kObjectInstanceFlagChunk | 
            kObjectInstanceFlagSun | 
            kObjectInstanceFlagMoon
            )
        )
    );

    if (isActor) {
        EvaluateActorMaterial(objectInstance, hitInfo, uv, tintColor0, tintColor1, color, surfaceInfo.shouldDiscard);
    }

    // applyActorDiffuse()
    // applyOverlayColor()
    if (objectInstance.flags & kObjectInstanceFlagUsesOverlayColor)
    {
        color.rgb = lerp(color.rgb, tintColor1.rgb, tintColor1.a);
    }

    // Gather PBR data
    if (geometryInfo.pbrTextureDataIndex != kInvalidPBRTextureHandle)
    {
        PBRTextureData pbr = pbrTextureDataBuffer[geometryInfo.pbrTextureDataIndex];

        float4 mers = float4(pbr.uniformMetalness, pbr.uniformEmissive, pbr.uniformRoughness, pbr.uniformSubsurface);
        if (pbr.flags & kPBRTextureDataFlagHasMaterialTexture)
        {
            float materialLod = useRayConeLod
                ? TransformTextureLod(textureLod, pbr.colourToMaterialUvScale, pbr.maxMipMer)
                : 0.0;
            float4 texel = colorTex.SampleLevel(pointSampler, uv * pbr.colourToMaterialUvScale + pbr.colourToMaterialUvBias, materialLod);
            mers.rgb = texel.rgb;
            if (pbr.flags & kPBRTextureDataFlagHasSubsurfaceChannel)
                mers.a = texel.a;
        }
        surfaceInfo.metalness = mers.r;
        surfaceInfo.emissive = mers.g;
        surfaceInfo.roughness = mers.b;
        surfaceInfo.subsurface = mers.a;

        if (pbr.flags & (kPBRTextureDataFlagHasNormalTexture | kPBRTextureDataFlagHasHeightMapTexture | kPBRTextureDataFlagHasPackedHeightNormalsTexture))
        {
            float2 normalUV = uv * pbr.colourToNormalUvScale + pbr.colourToNormalUvBias;

            float3 tangent = safeNormalize(mul(geometryInfo.tangent, (float3x3)objectInstance.modelToWorld), float3(1, 0, 0));
            float3 bitangent = safeNormalize(mul(geometryInfo.bitangent, (float3x3)objectInstance.modelToWorld), cross(surfaceInfo.normal, tangent));

            float3 texNormal = float3(0, 0, 1);
            if (pbr.flags & kPBRTextureDataFlagHasNormalTexture)
            {
                float2 texel = colorTex.SampleLevel(pointSampler, normalUV, 0).rg;
                texel = 2 * texel - 1;
                texNormal = float3(texel, sqrt(max(0, 1 - texel.x * texel.x - texel.y * texel.y)));
            }
            else if (pbr.flags & kPBRTextureDataFlagHasPackedHeightNormalsTexture)
            {
                // This code is based on the Vibrant Visuals implementation of heightmaps, with packed egde normals.

                // g_view.heightMapPixelEdgeWidth = 1/12
                // g_view.recipHeightMapDepth = 1/4
                const float kHeightMapFlattenEpsilon = 0.005;

                float4 pixelEgdeNormals = colorTex.SampleLevel(pointSampler, normalUV, 0);
                float2 widthHeight;
                colorTex.GetDimensions(widthHeight.x, widthHeight.y);
                float2 nudgeSampleCoord = frac(normalUV * widthHeight);
                pixelEgdeNormals = 2.0 * pixelEgdeNormals - 1.0;
                texNormal.xy = pixelEgdeNormals.yz * step(1.0 - g_view.heightMapPixelEdgeWidth, nudgeSampleCoord) - pixelEgdeNormals.wx * step(nudgeSampleCoord, g_view.heightMapPixelEdgeWidth);
                texNormal.xy *= step(kHeightMapFlattenEpsilon, abs(texNormal.xy));
                texNormal.z = g_view.recipHeightMapDepth;
                texNormal = safeNormalize(texNormal, float3(0, 0, 1));
            }
            else
            {
                // This code is based on the Vibrant Visuals implementation of traditional grayscale heightmaps.
                
                float2 widthHeight;
                colorTex.GetDimensions(widthHeight.x, widthHeight.y);
                float2 pixelCoord = normalUV * widthHeight;
                {
                    const float kNudgePixelCentreDistEpsilon = 0.0625;
                    const float kNudgeUvEpsilon = 0.25 / 65536.;
                    float2 nudgeSampleCoord = frac(pixelCoord);
                    if (abs(nudgeSampleCoord.x - 0.5) < kNudgePixelCentreDistEpsilon)
                    {
                        normalUV.x += (nudgeSampleCoord.x > 0.5f) ? kNudgeUvEpsilon : -kNudgeUvEpsilon;
                    }
                    if (abs(nudgeSampleCoord.y - 0.5) < kNudgePixelCentreDistEpsilon)
                    {
                        normalUV.y += (nudgeSampleCoord.y > 0.5f) ? kNudgeUvEpsilon : -kNudgeUvEpsilon;
                    }
                }
                float4 heightSamples = colorTex.Gather(pointSampler, normalUV, 0);
                float2 subPixelCoord = frac(pixelCoord + 0.5);
                const float kBevelMode = 0.0;
                float2 axisSamplePair = (subPixelCoord.y > 0.5) ? heightSamples.xy : heightSamples.wz;
                float axisBevelCentreSampleCoord = subPixelCoord.x;
                axisBevelCentreSampleCoord += ((axisSamplePair.x > axisSamplePair.y) ? g_view.heightMapPixelEdgeWidth : -g_view.heightMapPixelEdgeWidth) * kBevelMode;
                int2 axisSampleIndices = int2(clamp(float2(axisBevelCentreSampleCoord - g_view.heightMapPixelEdgeWidth, axisBevelCentreSampleCoord + g_view.heightMapPixelEdgeWidth) * 2.f, 0.0, 1.0));
                texNormal.x = (axisSamplePair[axisSampleIndices.x] - axisSamplePair[axisSampleIndices.y]);
                axisSamplePair = (subPixelCoord.x > 0.5f) ? heightSamples.zy : heightSamples.wx;
                axisBevelCentreSampleCoord = subPixelCoord.y;
                axisBevelCentreSampleCoord += ((axisSamplePair.x > axisSamplePair.y) ? g_view.heightMapPixelEdgeWidth : -g_view.heightMapPixelEdgeWidth) * kBevelMode;
                axisSampleIndices = int2(clamp(float2(axisBevelCentreSampleCoord - g_view.heightMapPixelEdgeWidth, axisBevelCentreSampleCoord + g_view.heightMapPixelEdgeWidth) * 2.f, 0.0, 1.0));
                texNormal.y = (axisSamplePair[axisSampleIndices.x] - axisSamplePair[axisSampleIndices.y]);
                texNormal.z = g_view.recipHeightMapDepth;
                texNormal = safeNormalize(texNormal, float3(0, 0, 1));
            }
            surfaceInfo.normal = safeNormalize(mul(texNormal, float3x3(tangent, bitangent, geometryInfo.geometryNormal)), surfaceInfo.normal);
        }
    }

    // Invert back facing normals.
    if (!hitInfo.frontFacing) surfaceInfo.normal = -surfaceInfo.normal;

    surfaceInfo.color = color.rgb;
    surfaceInfo.alpha = color.a;
    return surfaceInfo;
}

SurfaceInfo MaterialVanilla(HitInfo hitInfo, GeometryInfo geometryInfo, ObjectInstance objectInstance)
{
    return MaterialVanilla(hitInfo, geometryInfo, objectInstance, 0.0, float3(0, 0, 1));
}

float4 GetShadowColorAndAlpha(HitInfo hitInfo, ObjectInstance objectInstance, out float3 geoNormal)
{
    uint colorByteOffset = objectInstance.offsetPack2 & 0xff;
    uint uv0ByteOffset = objectInstance.offsetPack2 >> 8;
    uint positionByteOffset = objectInstance.offsetPack1 & 0xff;
    ByteAddressBuffer vertexBuffer = vertexBuffers[objectInstance.vbIdx];

    uint firstVertexOffsetInQuad = (hitInfo.primitiveId / 2) * 4;
    uint3 vertices = firstVertexOffsetInQuad + (hitInfo.primitiveId & 1 ? uint3(2, 3, 0) : uint3(0, 1, 2));
    float3 bary = float3(1 - hitInfo.barycentric2.x - hitInfo.barycentric2.y, hitInfo.barycentric2.xy);

    float4 vertColor = 0;
    float2 uv = 0;
    float3 positions[3];

    [unroll]
    for (uint i = 0; i < 3; ++i)
    {
        uint address = (vertices[i] + objectInstance.vertexOffsetInBaseVertices) * objectInstance.vertexStride;
        positions[i] = vertexBuffer.Load<float16_t4>(address + positionByteOffset).xyz;
        if (colorByteOffset) vertColor += bary[i] * unpackVertexColor(vertexBuffer.Load(address + colorByteOffset));
        uv += bary[i] * unpackVertexUV(vertexBuffer.Load(address + uv0ByteOffset), objectInstance.flags & kObjectInstanceFlagUsesUvBiasPacking);
    }
    if (!colorByteOffset) vertColor = 1;
    
    geoNormal = safeNormalize(cross((positions[1] - positions[0]), (positions[2] - positions[0])), float3(0, 1, 0));

    Texture2D colorTex = textures[objectInstance.colourTextureIdx != 0xffff ? objectInstance.colourTextureIdx : g_view.missingTextureIndex];
    float4 color = 1;
    if (objectInstance.colourTextureIdx != 0xffff)
    {
        color = colorTex.SampleLevel(pointSampler, uv, 0);
    }
    
    bool isTintShadedSurface = objectInstance.flags & (kObjectInstanceFlagChunk | kObjectInstanceFlagClouds) 
        && !(objectInstance.flags & kObjectInstanceFlagHasSeasonsTexture) 
        && vertColor.r == vertColor.g 
        && vertColor.g == vertColor.b  
        && vertColor.a >= 0.999;

    if (isTintShadedSurface) vertColor.rgb = 1;

    color.rgb *= vertColor.rgb;
    if (objectInstance.flags & kObjectInstanceFlagChunk) color.a *= vertColor.a;

    return color;
}

#endif
