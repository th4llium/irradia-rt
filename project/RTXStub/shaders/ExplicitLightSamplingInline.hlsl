#include "Include/Renderer.hlsl"
#include "Include/DenoisingCommon.hlsl"

[numthreads(4, 8, 1)]
void ExplicitLightSamplingInline(
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

    float3 position = inputPrimaryWorldPosition[pixelCoord].xyz;
    float3 normal = DecodeDenoiserNormal(inputBufferNormal[pixelCoord]);
    float3 rayDirection =
        safeNormalize(inputPrimaryViewDirection[pixelCoord].xyz, float3(0, 0, 1));
    float3 V = safeNormalize(-rayDirection, normal);
    float3 primaryThroughput = max(inputPrimaryThroughput[pixelCoord].rgb, 0.0);

    float4 baseAndMetal = inputBufferColourAndMetallic[pixelCoord];
    float3 baseColor = max(baseAndMetal.rgb, 0.0);
    float metalness = saturate(baseAndMetal.a);
    float3 diffuseColor = max(outputBufferRayThroughput[pixelCoord], 0.0);
    float4 emissionAndRoughness = outputBufferRayDirection[pixelCoord];
    float roughness = max(emissionAndRoughness.a, 0.035);
    float subsurface =
        saturate(inputBufferSurfaceOpacityAndObjectCategory[pixelCoord].y);
    float3 F0 = lerp((0.04).xxx, baseColor, metalness);
    float NdotV = max(dot(normal, V), 0.0001);

    float3 sunDir = getOffsetTrueDirectionToSun();
    float3 moonDir = getOffsetTrueDirectionToMoon();
    float sunFade = GetSunAmount(sunDir);
    float moonFade = GetMoonAmount(sunDir, moonDir);
    float isSun = step(moonFade, sunFade);
    float3 mainLightDir = lerp(moonDir, sunDir, isSun);
    float mainLightFade = lerp(moonFade, sunFade, isSun);

    float3 sunDiffuse = 0.0;
    float3 sunSpecular = 0.0;
    float NdotLMain = dot(normal, mainLightDir);
    float3 shadowTransmission = outputBufferSunLightShadow[pixelCoord].rgb;
    if (NdotLMain > 0.0 && any(shadowTransmission > 0.0)) {
        float3 L = mainLightDir;
        float3 H = safeNormalize(V + L, normal);
        float NdotL = max(NdotLMain, 0.0001);
        float NdotH = max(dot(normal, H), 0.0);
        float LdotH = max(dot(L, H), 0.0);

        float3 F = F_Schlick(max(dot(H, V), 0.0), F0);
        float D = D_GGX(NdotH, roughness);
        float G = G_Smith(NdotV, NdotL, roughness);
        float3 multipleScatter =
            FdezAgueraMultipleScattering(NdotV, NdotL, roughness, F0);
        float3 specBRDF =
            ((F * D * G) / (4.0 * NdotV * NdotL)) + multipleScatter;

        float3 kD = DiffuseEnergyWeight(F, multipleScatter);
        float3 diffuseBRDF =
            DisneyDiffuse(NdotL, NdotV, LdotH, roughness, diffuseColor);
        if (subsurface > 0.001) {
            diffuseBRDF = lerp(
                diffuseBRDF,
                BurleyNormalizedSSS(
                    NdotL, NdotV, LdotH, roughness, diffuseColor),
                subsurface);
        }
        diffuseBRDF *= kD;

        float3 sunRadiance;
        float sunLux;
        GetSunColorAndLux(position, sunDir, sunRadiance, sunLux);
        float3 moonRadiance;
        float moonLux;
        GetMoonColorAndLux(position, sunDir, moonDir, moonRadiance, moonLux);
        float3 mainRadiance = lerp(moonRadiance, sunRadiance, isSun);

        float3 lightContrib =
            mainRadiance * 0.75 * mainLightFade
            * shadowTransmission * NdotL * PI;
        sunDiffuse = lightContrib * diffuseBRDF;
        sunSpecular = lightContrib * specBRDF;
    }

    float3 directDiffuse = 0.0;
    float3 directSpecular = 0.0;
    AccumulateShadowedPointLights(
        position,
        normal,
        V,
        F0,
        diffuseColor,
        roughness,
        subsurface,
        GetPointLightBlueNoise(pixelCoord),
        directDiffuse,
        directSpecular);

    float exposure = GetAutoExposureMultiplier(
        g_view.viewOriginSteveSpace,
        sunDir,
        moonDir);
    float3 directEmission =
        (sunDiffuse + sunSpecular) * exposure * primaryThroughput;

    outputBufferRayDirection[pixelCoord] =
        float4(emissionAndRoughness.rgb + directEmission, emissionAndRoughness.a);

    float4 diffuse = outputBufferIndirectDiffuse[pixelCoord];
    diffuse.rgb +=
        directDiffuse * primaryThroughput / max(diffuseColor, 0.001);
    outputBufferIndirectDiffuse[pixelCoord] = diffuse;

    float4 specular = outputBufferIndirectSpecular[pixelCoord];
    specular.rgb += directSpecular * primaryThroughput;
    outputBufferIndirectSpecular[pixelCoord] = specular;
}
