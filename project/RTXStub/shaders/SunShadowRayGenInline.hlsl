#include "Include/Renderer.hlsl"
#include "Include/DenoisingCommon.hlsl"

[numthreads(4, 8, 1)]
void SunShadowRayGenInline(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex,
    uint3 groupID : SV_GroupID
    )
{
    uint2 pixelCoord = dispatchThreadID.xy;
    if (any(pixelCoord >= g_view.renderResolution))
        return;

    outputBufferSunLightShadow[pixelCoord] = 0.0;

    float depth = inputBufferPrimaryPathLength[pixelCoord];
    if (depth >= 65000.0)
        return;

    uint materialClass =
        (uint)round(inputPrimaryWorldPosition[pixelCoord].w);
    if (materialClass != kPrimaryMaterialOpaque)
        return;

    float3 normal = DecodeDenoiserNormal(inputBufferNormal[pixelCoord]);
    float3 position = inputPrimaryWorldPosition[pixelCoord].xyz;
    float3 sunDir = getOffsetTrueDirectionToSun();
    float3 moonDir = getOffsetTrueDirectionToMoon();
    float sunFade = GetSunAmount(sunDir);
    float moonFade = GetMoonAmount(sunDir, moonDir);
    float isSun = step(moonFade, sunFade);
    float3 mainLightDir = lerp(moonDir, sunDir, isSun);

    if (dot(normal, mainLightDir) <= 0.0)
        return;

    RayDesc shadowRay;
    shadowRay.Origin = position + 1.0e-4 * normal;
    shadowRay.Direction = mainLightDir;
    shadowRay.TMin = 0.0;
    shadowRay.TMax = 10000.0;

    ShadowPayload payload;
    TraceShadowRay(shadowRay, payload);

    outputBufferSunLightShadow[pixelCoord] =
        float4(ShapeSunShadowTransmission(payload.transmission), 1.0 / 255.0);
}
