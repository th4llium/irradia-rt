#include "Include/Generated/Signature.hlsl"

[numthreads(128, 1, 1)]
void ClearVertexIrradianceCache(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    uint vertexBufferIndex = g_rootConstant0 & 0xfff;
    uint numOfVertices = g_rootConstant0 >> 12;
    uint firstVertexOffset = g_rootConstant1;
    uint vertexId = dispatchThreadID.x;

    if(vertexId >= numOfVertices) return;
    vertexId += firstVertexOffset;

    VertexIrradianceCache emptyCache;
    emptyCache.incomingFrontAndHistoryLength = (half4)0;
    emptyCache.incomingBackAndPad = (half4)0;
    vertexIrradianceCache[vertexBufferIndex][vertexId] =
        emptyCache;
}
