#include "Include/Generated/Signature.hlsl"
#include "Include/Util.hlsl"

// Final Compositing Pass

[numthreads(16, 16, 1)]
void FinalCombine(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    uint2 pixelPos = dispatchThreadID.xy;
    if (any(pixelPos >= g_view.renderResolution)) return;

    uint diffuseDenoisingBufferIndex = g_rootConstant0 & 0xff;
    uint specularDenoisingBufferIndex = (g_rootConstant0 >> 8) & 0xff;
    uint shadowDenoisingBufferIndex = (g_rootConstant0 >> 16) & 0xff;


    Texture2D<float4> denoisedDiffuseInput = denoisingInputs[diffuseDenoisingBufferIndex];
    float3 denoisedDiffuse = denoisedDiffuseInput[pixelPos].rgb;

    Texture2D<float4> denoisedSpecularInput = denoisingInputs[specularDenoisingBufferIndex];
    float3 denoisedSpecular = denoisedSpecularInput[pixelPos].rgb;

    float3 albedo = outputBufferRayThroughput[pixelPos];

    float3 emission = outputBufferRayDirection[pixelPos].rgb;

    float3 diffuse = albedo * denoisedDiffuse;
    
    float3 finalColor = diffuse + denoisedSpecular + emission;

    finalColor = max(finalColor, 0.0);
    
    outputBufferFinal[pixelPos] = float4(finalColor, 1.0);
}