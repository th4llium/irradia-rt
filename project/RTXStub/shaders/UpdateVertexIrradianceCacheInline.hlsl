#include "Include/IrradianceCacheUpdate.hlsl"

[numthreads(32, 1, 1)]
void UpdateVertexIrradianceCacheInline(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    const uint kVertsPerCacheUpdateChunk = 16;

    uint randomSeed = g_rootConstant0;
    uint vertexIndex = dispatchThreadID.x;
    
    VertexIrradianceCacheUpdateChunk updateChunk = vertexIrradianceCacheUpdateChunks[vertexIndex / kVertsPerCacheUpdateChunk];
    uint chunkRelativeVertexIndex = vertexIndex % kVertsPerCacheUpdateChunk;

    uint objectInstanceIndex = updateChunk.objectInstanceIdxAndNumVertices & 0xffff;
    uint numVerticesInChunk = updateChunk.objectInstanceIdxAndNumVertices >> 16;

    if(chunkRelativeVertexIndex >= numVerticesInChunk) return;
    vertexIndex = updateChunk.firstVertexIdx + chunkRelativeVertexIndex;

    ObjectInstance objectInstance =
        objectInstances[objectInstanceIndex];
    if (!ObjectUsesIrradianceCache(objectInstance))
        return;

    float3 worldPosition;
    float3 worldNormal;
    GetIrradianceCacheVertexGeometry(
        objectInstance,
        vertexIndex,
        worldPosition,
        worldNormal);

    uint rngState = GetIrradianceCacheSeed(
        worldPosition,
        worldNormal,
        randomSeed);
    float2 frontRotation =
        CacheRandom2(rngState);
    float2 backRotation =
        CacheRandom2(rngState);

    float3 frontSample = 0.0;
    float3 backSample = 0.0;
    [unroll]
    for (uint sampleIndex = 0;
        sampleIndex < IRRADIANCE_CACHE_RAYS_PER_HEMISPHERE;
        ++sampleIndex)
    {
        RayDesc frontRay;
        frontRay.Origin =
            worldPosition + worldNormal * 1.0e-3;
        frontRay.Direction = SampleCosineHemisphere(
            GetCacheRaySample(
                sampleIndex,
                IRRADIANCE_CACHE_RAYS_PER_HEMISPHERE,
                frontRotation),
            worldNormal);
        frontRay.TMin = 0.0;
        frontRay.TMax = 10000.0;
        frontSample +=
            TraceCacheRadiance(frontRay);

        RayDesc backRay;
        backRay.Origin =
            worldPosition - worldNormal * 1.0e-3;
        backRay.Direction = SampleCosineHemisphere(
            GetCacheRaySample(
                sampleIndex,
                IRRADIANCE_CACHE_RAYS_PER_HEMISPHERE,
                backRotation),
            -worldNormal);
        backRay.TMin = 0.0;
        backRay.TMax = 10000.0;
        backSample +=
            TraceCacheRadiance(backRay);
    }
    float sampleScale =
        PI / IRRADIANCE_CACHE_RAYS_PER_HEMISPHERE;
    frontSample *= sampleScale;
    backSample *= sampleScale;

    uint cacheIndex = GetIrradianceCacheVertexIndex(
        objectInstance, vertexIndex);
    VertexIrradianceCache previousCache =
        vertexIrradianceCache[objectInstance.vbIdx][cacheIndex];
    float historyLength =
        float(previousCache.incomingFrontAndHistoryLength.w);
    float historyLimit =
        GetIrradianceCacheHistoryLimit(objectInstance);

    VertexIrradianceCache updatedCache;
    updatedCache.incomingFrontAndHistoryLength = half4(
        BlendCacheHistory(
            float3(previousCache.incomingFrontAndHistoryLength.xyz),
            frontSample,
            historyLength,
            historyLimit),
        min(historyLength + 1.0, historyLimit));
    updatedCache.incomingBackAndPad = half4(
        BlendCacheHistory(
            float3(previousCache.incomingBackAndPad.xyz),
            backSample,
            historyLength,
            historyLimit),
        0.0);
    vertexIrradianceCache[objectInstance.vbIdx][cacheIndex] =
        updatedCache;
}
