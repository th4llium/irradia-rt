#include "Include/Generated/Signature.hlsl"
#include "Include/DenoisingCommon.hlsl"

float ShadowDepthWeight(float centerDepth, float sampleDepth, int2 offset)
{
    float depthDelta = abs(centerDepth - sampleDepth);
    float relativeDepth = depthDelta / max(centerDepth, 0.001);
    float pixelDistance = length((float2)offset);
    return exp(-relativeDepth * 128.0 - depthDelta * 1.25 - pixelDistance * 0.12);
}

float ShadowNormalWeight(float3 centerNormal, float3 sampleNormal)
{
    return pow(saturate(dot(centerNormal, sampleNormal)), 224.0);
}

float ShadowTransmissionWeight(float3 centerShadow, float3 sampleShadow)
{
    float centerVisibility = getLuminance(centerShadow);
    float sampleVisibility = getLuminance(sampleShadow);
    float visibilityDelta = abs(centerVisibility - sampleVisibility);
    float edgeStop = exp(-visibilityDelta * 8.0);

    float brightLeakGuard =
        sampleVisibility > centerVisibility
            ? exp(-(sampleVisibility - centerVisibility) * 18.0)
            : 1.0;
    if (sampleVisibility > centerVisibility && centerVisibility < 0.60)
        brightLeakGuard *= exp(-(sampleVisibility - centerVisibility) * 10.0);
    return edgeStop * brightLeakGuard;
}

float3 ClampShadowLeakage(float4 centerShadow, float3 filteredShadow)
{
    float centerVisibility = getLuminance(centerShadow.rgb);
    float historyLength = saturate(centerShadow.a) * 255.0;
    float maxBrightening =
        lerp(0.010, 0.045, smoothstep(1.0, 32.0, historyLength));
    float3 upperBound = centerShadow.rgb + maxBrightening.xxx;

    if (centerVisibility < 0.65)
        filteredShadow = min(filteredShadow, upperBound);

    return saturate(filteredShadow);
}

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
    uint iteration = min(g_rootConstant0 & 0xff, 2u);
    int stepSize = (int)(1u << iteration);

    Texture2D<float4> shadowInput = shadowDenoisingInputs[shadowDenoisingInputBufferIndex];
    RWTexture2D<float4> shadowOutput = shadowDenoisingOutputs[shadowDenoisingOutputBufferIndex];

    float4 center = shadowInput[pixelPos];
    shadowOutput[pixelPos] = center;
    return;

    float centerDepth = inputBufferPrimaryPathLength[pixelPos];
    if (centerDepth >= 65000.0) {
        shadowOutput[pixelPos] = center;
        return;
    }

    float3 centerNormal = DecodeDenoiserNormal(inputBufferNormal[pixelPos]);
    float centerWeight = 1.60;
    float3 shadowSum = center.rgb * centerWeight;
    float weightSum = centerWeight;
    int2 renderSize = int2(g_view.renderResolution);
    static const float kernel[2] = { 1.0, 0.5 };

    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            if (x == 0 && y == 0)
                continue;

            int2 offset = int2(x, y) * stepSize;
            int2 samplePixel = int2(pixelPos) + offset;
            if (any(samplePixel < 0) || any(samplePixel >= renderSize))
                continue;

            float sampleDepth = inputBufferPrimaryPathLength[samplePixel];
            if (sampleDepth >= 65000.0)
                continue;

            float3 sampleNormal =
                DecodeDenoiserNormal(inputBufferNormal[samplePixel]);
            float3 sampleShadow = shadowInput[samplePixel].rgb;
            float weight =
                kernel[abs(x)]
                * kernel[abs(y)]
                * ShadowNormalWeight(centerNormal, sampleNormal)
                * ShadowDepthWeight(centerDepth, sampleDepth, offset)
                * ShadowTransmissionWeight(center.rgb, sampleShadow);

            shadowSum += sampleShadow * weight;
            weightSum += weight;
        }
    }

    shadowOutput[pixelPos] =
        float4(
            ClampShadowLeakage(
                center,
                shadowSum / max(weightSum, 1.0e-4)),
            center.a);
}
