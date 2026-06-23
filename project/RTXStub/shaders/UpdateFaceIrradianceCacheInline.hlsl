#include "Include/IrradianceCacheUpdate.hlsl"

[numthreads(32, 1, 1)]
void UpdateFaceIrradianceCacheInline(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    const uint kFacesPerCacheUpdateChunk = 16;

    uint faceIndex = dispatchThreadID.x;
    
    FaceIrradianceCacheUpdateChunk updateChunk = faceIrradianceCacheUpdateChunks[faceIndex / kFacesPerCacheUpdateChunk];
    uint chunkRelativeFaceIndex = faceIndex % kFacesPerCacheUpdateChunk;

    uint objectInstanceIndex = updateChunk.objectInstanceIdxAndNumFaces & 0xffff;
    uint numFacesInChunk = updateChunk.objectInstanceIdxAndNumFaces >> 16;

    if(chunkRelativeFaceIndex >= numFacesInChunk) return;
    faceIndex = updateChunk.firstFaceIdx + chunkRelativeFaceIndex;

    ObjectInstance objectInstance =
        objectInstances[objectInstanceIndex];
    if (!ObjectUsesIrradianceCache(objectInstance))
        return;

    float3 incomingFront = 0.0;
    float3 incomingBack = 0.0;
    float incomingWeight = 0.0;
    uint firstVertexInFace = faceIndex * 4;
    [unroll]
    for (uint vertexInFace = 0; vertexInFace < 4; ++vertexInFace)
    {
        uint cacheVertexIndex = GetIrradianceCacheVertexIndex(
            objectInstance,
            firstVertexInFace + vertexInFace);
        VertexIrradianceCache vertexCache =
            vertexIrradianceCache[
                objectInstance.vbIdx][cacheVertexIndex];
        float vertexConfidence =
            GetIrradianceCacheConfidence(float(
                vertexCache
                    .incomingFrontAndHistoryLength.w));
        incomingFront +=
            float3(
                vertexCache
                    .incomingFrontAndHistoryLength.xyz)
            * vertexConfidence;
        incomingBack +=
            float3(vertexCache.incomingBackAndPad.xyz)
            * vertexConfidence;
        incomingWeight += vertexConfidence;
    }
    if (incomingWeight > 0.0001)
    {
        incomingFront /= incomingWeight;
        incomingBack /= incomingWeight;
    }

    HitInfo frontHit;
    frontHit.rayT = 0.0;
    frontHit.frontFacing = true;
    frontHit.barycentric2 = float2(1.0 / 3.0, 1.0 / 3.0);
    frontHit.materialType = MATERIAL_TYPE_OPAQUE;
    frontHit.objectInstanceIndex = objectInstanceIndex;
    frontHit.primitiveId = faceIndex * 2;

    HitInfo backHit = frontHit;
    backHit.frontFacing = false;

    float3 frontSample = EvaluateCachedOutgoingRadiance(
        frontHit, objectInstance, incomingFront);
    float3 backSample = EvaluateCachedOutgoingRadiance(
        backHit, objectInstance, incomingBack);

    uint cacheIndex = GetIrradianceCacheFaceIndex(
        objectInstance, faceIndex);
    FaceIrradianceCache previousCache =
        faceIrradianceCache[objectInstance.vbIdx][cacheIndex];
    float historyLength =
        float(previousCache.outgoingFrontAndHistoryLength.w);
    float historyLimit =
        GetIrradianceCacheHistoryLimit(objectInstance);

    FaceIrradianceCache updatedCache;
    updatedCache.outgoingFrontAndHistoryLength = half4(
        BlendCacheHistory(
            float3(previousCache.outgoingFrontAndHistoryLength.xyz),
            frontSample,
            historyLength,
            historyLimit),
        min(historyLength + 1.0, historyLimit));
    updatedCache.outgoingBackAndPad = half4(
        BlendCacheHistory(
            float3(previousCache.outgoingBackAndPad.xyz),
            backSample,
            historyLength,
            historyLimit),
        0.0);
    faceIrradianceCache[objectInstance.vbIdx][cacheIndex] =
        updatedCache;
}
