#include "Include/Renderer.hlsl"
#include "Include/DenoisingCommon.hlsl"

[numthreads(4, 8, 1)]
void SpecularRayGenInline(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex,
    uint3 groupID : SV_GroupID
    )
{
    uint2 pixelCoord = dispatchThreadID.xy;
    if (any(pixelCoord >= g_view.renderResolution))
        return;

    float depth = inputBufferPrimaryPathLength[pixelCoord];
    if (depth >= 65000.0)
        return;

    uint materialClass =
        (uint)round(inputPrimaryWorldPosition[pixelCoord].w);
    if (materialClass != kPrimaryMaterialOpaque)
        return;

    float4 baseAndMetal = inputBufferColourAndMetallic[pixelCoord];
    float3 baseColor = max(baseAndMetal.rgb, 0.0);
    float metalness = saturate(baseAndMetal.a);
    float roughness = saturate(outputBufferRayDirection[pixelCoord].a);
    float smoothness = saturate((0.72 - roughness) / 0.72);
    float3 normal = DecodeDenoiserNormal(inputBufferNormal[pixelCoord]);
    float3 rayDirection =
        safeNormalize(inputPrimaryViewDirection[pixelCoord].xyz, float3(0, 0, 1));
    float3 V = safeNormalize(-rayDirection, normal);
    float NdotV = max(dot(normal, V), 0.0001);
    float3 F0 = lerp((0.04).xxx, baseColor, metalness);
    float3 F = F_Schlick(NdotV, F0);
    float reflectionImportance =
        smoothness * smoothness
        * max(getLuminance(F), metalness * 0.35);

    if (reflectionImportance <= 0.006)
        return;

    float3 reflectionDirection =
        safeNormalize(reflect(rayDirection, normal), normal);
    float maxDistance =
        lerp(
            48.0,
            PERF_DIELECTRIC_REFLECTION_PROBE_DISTANCE,
            saturate(smoothness + metalness));

    float3 reflectedRadiance =
        TraceDielectricReflectionProbe(
            inputPrimaryWorldPosition[pixelCoord].xyz,
            normal,
            reflectionDirection,
            maxDistance,
            false);
    float3 primaryThroughput =
        max(inputPrimaryThroughput[pixelCoord].rgb, 0.0);
    float3 probeSpecular =
        reflectedRadiance
        * F
        * smoothness
        * primaryThroughput;

    float4 specular = outputBufferIndirectSpecular[pixelCoord];
    specular.rgb += ClampIndirectRadiance(probeSpecular, 64.0);
    outputBufferIndirectSpecular[pixelCoord] = specular;

    outputBufferReflectionDistance[pixelCoord] = maxDistance;
    outputBufferReflectionMotionVectors[pixelCoord] = 0.0;
}
