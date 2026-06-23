#include "Include/Generated/Signature.hlsl"

[numthreads(16, 16, 1)]
void ShadowDenoising(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    uint2 pixelPos = dispatchThreadID.xy;
    if (any(pixelPos >= g_view.renderResolution)) return;

    uint shadowDenoisingInputBufferIndex = (g_rootConstant0 >> 8) & 0xff;
    uint shadowDenoisingOutputBufferIndex = (g_rootConstant0 >> 16) & 0xff;

    Texture2D<float4> shadowInput = shadowDenoisingInputs[shadowDenoisingInputBufferIndex];
    RWTexture2D<float4> shadowOutput = shadowDenoisingOutputs[shadowDenoisingOutputBufferIndex];

    shadowOutput[pixelPos] = shadowInput[pixelPos];
}