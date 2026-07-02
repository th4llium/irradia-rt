#ifndef __IRRADIANCE_CACHE_HLSL__
#define __IRRADIANCE_CACHE_HLSL__

#include "Material.hlsl"

#ifndef IRRADIANCE_CACHE_CONFIDENCE_HISTORY
#define IRRADIANCE_CACHE_CONFIDENCE_HISTORY 12.0
#endif

#ifndef IRRADIANCE_CACHE_MAX_LUMINANCE
#define IRRADIANCE_CACHE_MAX_LUMINANCE PERF_IRRADIANCE_CACHE_MAX_LUMINANCE
#endif

struct IrradianceCacheSample
{
    float3 irradiance;
    float confidence;
};

uint GetIrradianceCacheVertexIndex(
    ObjectInstance objectInstance,
    uint localVertexIndex)
{
    return objectInstance.vertexOffsetInParallelVertices
        + localVertexIndex;
}

uint GetIrradianceCacheFaceIndex(
    ObjectInstance objectInstance,
    uint localFaceIndex)
{
    return objectInstance.vertexOffsetInParallelVertices / 4
        + localFaceIndex;
}

float3 ClampCachedIrradiance(float3 value)
{
    if (any(isnan(value)) || any(isinf(value)))
        return (0.0).xxx;

    value = max(value, 0.0);
    float luminance = dot(value, float3(0.2126, 0.7152, 0.0722));
    if (luminance > IRRADIANCE_CACHE_MAX_LUMINANCE)
        value *= IRRADIANCE_CACHE_MAX_LUMINANCE / luminance;
    return value;
}

float GetIrradianceCacheConfidence(float historyLength)
{
    return saturate(
        historyLength / IRRADIANCE_CACHE_CONFIDENCE_HISTORY);
}

bool ObjectUsesIrradianceCache(ObjectInstance objectInstance)
{
    return g_view.enableIrradianceCache != 0
        && (objectInstance.flags
            & kObjectInstanceFlagUsesIrradianceCache) != 0;
}

IrradianceCacheSample SampleIncomingIrradianceCache(
    HitInfo hitInfo,
    ObjectInstance objectInstance)
{
    IrradianceCacheSample sample;
    sample.irradiance = 0.0;
    sample.confidence = 0.0;

    if (!ObjectUsesIrradianceCache(objectInstance))
        return sample;

    float3 barycentric = float3(
        1.0 - hitInfo.barycentric2.x - hitInfo.barycentric2.y,
        hitInfo.barycentric2);

    float2 quadUv = (hitInfo.primitiveId & 1) == 0
        ? float2(
            barycentric.y + barycentric.z,
            barycentric.z)
        : float2(
            barycentric.x,
            barycentric.x + barycentric.y);
    quadUv = saturate(quadUv);
    float4 quadWeights = float4(
        (1.0 - quadUv.x) * (1.0 - quadUv.y),
        quadUv.x * (1.0 - quadUv.y),
        quadUv.x * quadUv.y,
        (1.0 - quadUv.x) * quadUv.y);

    uint firstVertexInFace = (hitInfo.primitiveId / 2) * 4;
    float minimumHistoryLength = 65504.0;
    float averageHistoryLength = 0.0;
    [unroll]
    for (uint i = 0; i < 4; ++i)
    {
        VertexIrradianceCache cache = vertexIrradianceCache[
            objectInstance.vbIdx][GetIrradianceCacheVertexIndex(
                objectInstance, firstVertexInFace + i)];

        float3 incoming = hitInfo.frontFacing
            ? float3(cache.incomingFrontAndHistoryLength.xyz)
            : float3(cache.incomingBackAndPad.xyz);
        float historyLength =
            float(cache.incomingFrontAndHistoryLength.w);

        sample.irradiance += quadWeights[i] * incoming;
        minimumHistoryLength =
            min(minimumHistoryLength, historyLength);
        averageHistoryLength +=
            quadWeights[i] * historyLength;
    }

    sample.irradiance =
        ClampCachedIrradiance(sample.irradiance);
    float reliableHistoryLength = lerp(
        minimumHistoryLength,
        averageHistoryLength,
        0.25);
    sample.confidence = GetIrradianceCacheConfidence(
        reliableHistoryLength);
    return sample;
}

float3 SampleOutgoingRadianceCache(
    HitInfo hitInfo,
    ObjectInstance objectInstance,
    out float confidence)
{
    confidence = 0.0;
    if (!ObjectUsesIrradianceCache(objectInstance))
        return (0.0).xxx;

    uint localFaceIndex = hitInfo.primitiveId / 2;
    FaceIrradianceCache cache = faceIrradianceCache[
        objectInstance.vbIdx][GetIrradianceCacheFaceIndex(
            objectInstance, localFaceIndex)];

    float3 outgoing = hitInfo.frontFacing
        ? float3(cache.outgoingFrontAndHistoryLength.xyz)
        : float3(cache.outgoingBackAndPad.xyz);
    confidence = GetIrradianceCacheConfidence(
        float(cache.outgoingFrontAndHistoryLength.w));
    return ClampCachedIrradiance(outgoing);
}

void GetIrradianceCacheVertexGeometry(
    ObjectInstance objectInstance,
    uint localVertexIndex,
    out float3 worldPosition,
    out float3 worldNormal)
{
    uint positionByteOffset = objectInstance.offsetPack1 & 0xff;
    uint normalByteOffset = objectInstance.offsetPack1 >> 8;
    ByteAddressBuffer vertexBuffer =
        vertexBuffers[objectInstance.vbIdx];

    uint vertexAddress =
        (localVertexIndex + objectInstance.vertexOffsetInBaseVertices)
        * objectInstance.vertexStride;
    float3 localPosition =
        vertexBuffer.Load<float16_t4>(
            vertexAddress + positionByteOffset).xyz;

    uint firstVertexInFace = (localVertexIndex / 4) * 4;
    float3 facePositions[3];
    [unroll]
    for (uint i = 0; i < 3; ++i)
    {
        uint address =
            (firstVertexInFace + i
                + objectInstance.vertexOffsetInBaseVertices)
            * objectInstance.vertexStride;
        facePositions[i] = vertexBuffer.Load<float16_t4>(
            address + positionByteOffset).xyz;
    }

    float3 localFaceNormal = safeNormalize(
        cross(
            facePositions[1] - facePositions[0],
            facePositions[2] - facePositions[0]),
        float3(0, 1, 0));
    float3 localNormal = normalByteOffset != 0
        ? unpackNormal(
            vertexBuffer.Load(vertexAddress + normalByteOffset)).xyz
        : localFaceNormal;

    worldPosition = mul(
        float4(localPosition, 1.0),
        objectInstance.modelToWorld);
    worldNormal = safeNormalize(
        mul(localNormal, (float3x3)objectInstance.modelToWorld),
        safeNormalize(
            mul(localFaceNormal, (float3x3)objectInstance.modelToWorld),
            float3(0, 1, 0)));
}

#endif
