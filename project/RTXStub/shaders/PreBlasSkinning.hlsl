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

#include "Include/Generated/Signature.hlsl"
#include "Include/Util.hlsl"

[numthreads(64, 1, 1)]
void PreBlasSkinning(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    if (dispatchThreadID.x >= g_meshSkinningData.vertexCount) return;

    RWByteAddressBuffer sourceBuffer =
        vertexBuffersRW[g_meshSkinningData.sourceVBIndex];
    RWByteAddressBuffer destinationBuffer =
        vertexBuffersRW[g_meshSkinningData.destVBIndex];

    uint sourceAddress =
        dispatchThreadID.x * g_meshSkinningData.sizeOfVertex
        + g_meshSkinningData.sourceVBOffset;
    uint destinationAddress =
        dispatchThreadID.x * g_meshSkinningData.sizeOfVertex
        + g_meshSkinningData.destVBOffset;

    float16_t4 previousPosition;
    if (g_meshSkinningData.offsetToPrevPos != 0xFFFFFFFF) {
        previousPosition = destinationBuffer.Load<float16_t4>(
            destinationAddress + g_meshSkinningData.offsetToPosition);
    }

    for (uint byteOffset = 0;
        byteOffset < g_meshSkinningData.sizeOfVertex;
        byteOffset += 4)
    {
        destinationBuffer.Store(
            destinationAddress + byteOffset,
            sourceBuffer.Load(sourceAddress + byteOffset));
    }

    if (g_meshSkinningData.offsetToPrevPos != 0xFFFFFFFF) {
        destinationBuffer.Store<float16_t4>(
            destinationAddress + g_meshSkinningData.offsetToPrevPos,
            previousPosition);
    }
    
    uint boneIndex = sourceBuffer.Load<uint16_t>(
        sourceAddress + g_meshSkinningData.offsetToBoneIndex);
    if (boneIndex > 7) return;
    
    float4x4 bone = g_meshSkinningData.bones[boneIndex];

    float16_t4 position = sourceBuffer.Load<float16_t4>(
        sourceAddress + g_meshSkinningData.offsetToPosition);
    position = (float16_t4)mul(bone, position);
    destinationBuffer.Store<float16_t4>(
        destinationAddress + g_meshSkinningData.offsetToPosition,
        position);

    uint normalPacked = sourceBuffer.Load<uint>(
        sourceAddress + g_meshSkinningData.offsetToNormal);
    float4 normal = unpackNormal(normalPacked);
    normal = mul(bone, normal);
    normal.xyz = normalize(normal.xyz);
    destinationBuffer.Store(
        destinationAddress + g_meshSkinningData.offsetToNormal,
        packNormal(normal));
}
