#include "Include/Generated/Signature.hlsl"
#include "Include/DenoisingCommon.hlsl"

static const float TAA_SKY_DISTANCE = 65000.0;

bool TAAIsFinite(float3 value)
{
    return !any(isnan(value)) && !any(isinf(value));
}

uint2 TAADisplayToRenderPixel(uint2 displayPixel)
{
    float2 renderPosition =
        ((float2)displayPixel + 0.5)
        * g_view.renderResolution
        / max(g_view.displayResolution, 1.0);
    return min(
        (uint2)floor(renderPosition),
        (uint2)g_view.renderResolution - 1u);
}

bool TAAInsideDisplay(int2 pixel)
{
    return all(pixel >= int2(0, 0))
        && all(pixel < int2(g_view.displayResolution));
}

bool TAAInsideRender(int2 pixel)
{
    return all(pixel >= int2(0, 0))
        && all(pixel < int2(g_view.renderResolution));
}

float3 TAALoadCurrentColor(int2 pixel)
{
    return max(inputFinalColour[pixel].rgb, 0.0);
}

float3 TAALoadHistoryBilinear(
    float2 previousPixelCenter,
    out float historyWeight)
{
    float2 previousCorner = previousPixelCenter - 0.5;
    int2 basePixel = int2(floor(previousCorner));
    float2 bilinear = frac(previousCorner);

    float3 history = 0.0;
    historyWeight = 0.0;

    [unroll]
    for (int sampleIndex = 0; sampleIndex < 4; ++sampleIndex)
    {
        int2 offset = int2(sampleIndex & 1, (sampleIndex >> 1) & 1);
        int2 samplePixel = basePixel + offset;
        if (!TAAInsideDisplay(samplePixel))
            continue;

        float2 weightPair = lerp(1.0 - bilinear, bilinear, (float2)offset);
        float weight = weightPair.x * weightPair.y;
        float3 sampleColor = max(inputTAAHistory[samplePixel].rgb, 0.0);
        if (!TAAIsFinite(sampleColor))
            continue;

        history += sampleColor * weight;
        historyWeight += weight;
    }

    return history / max(historyWeight, 1.0e-5);
}

void TAAGetNeighborhood(
    uint2 pixel,
    out float3 neighborhoodMin,
    out float3 neighborhoodMax,
    out float neighborMaxLuminance)
{
    int2 center = int2(pixel);
    neighborhoodMin = TAALoadCurrentColor(center);
    neighborhoodMax = neighborhoodMin;
    neighborMaxLuminance = 0.0;

    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            int2 samplePixel = center + int2(x, y);
            if (!TAAInsideDisplay(samplePixel))
                continue;

            float3 sampleColor = TAALoadCurrentColor(samplePixel);
            neighborhoodMin = min(neighborhoodMin, sampleColor);
            neighborhoodMax = max(neighborhoodMax, sampleColor);
            if (x != 0 || y != 0)
                neighborMaxLuminance = max(
                    neighborMaxLuminance,
                    getLuminance(sampleColor));
        }
    }
}

float3 TAAClipHistory(
    float3 history,
    float3 neighborhoodMin,
    float3 neighborhoodMax)
{
    float3 range = neighborhoodMax - neighborhoodMin;
    float3 margin = max(
        range * 0.45,
        max(neighborhoodMax * 0.04, (0.015).xxx));
    return clamp(
        history,
        neighborhoodMin - margin,
        neighborhoodMax + margin);
}

float3 TAAClampCurrentFirefly(
    float3 current,
    float neighborMaxLuminance,
    float emissionLuminance)
{
    float currentLuminance = getLuminance(current);
    float isolatedLimit = max(neighborMaxLuminance * 3.0 + 0.75, 8.0);
    if (emissionLuminance < 0.10 && currentLuminance > isolatedLimit)
        current *= isolatedLimit / max(currentLuminance, 1.0e-4);

    return current;
}

bool TAAHistoryGeometryValid(
    uint2 renderPixel,
    float2 previousDisplayCenter)
{
    float2 renderScale =
        g_view.renderResolution / max(g_view.displayResolution, 1.0);
    int2 previousRenderPixel =
        int2(floor(previousDisplayCenter * renderScale));
    if (!TAAInsideRender(previousRenderPixel))
        return false;

    float currentDepth = inputBufferPrimaryPathLength[renderPixel];
    float previousDepth = previousPrimaryPathLengthBuffer[previousRenderPixel];
    bool currentSky = currentDepth >= TAA_SKY_DISTANCE;
    bool previousSky = previousDepth >= TAA_SKY_DISTANCE;
    if (currentSky || previousSky)
        return currentSky == previousSky;

    float expectedPreviousDepth =
        inputBufferReprojectedPathLength[renderPixel];
    if (abs(previousDepth - expectedPreviousDepth)
        > GetReprojectionDepthTolerance(expectedPreviousDepth) * 2.5)
    {
        return false;
    }

    float3 currentNormal =
        DecodeDenoiserNormal(inputBufferNormal[renderPixel]);
    float3 previousNormal =
        DecodeDenoiserNormal(previousPrimaryNormalBuffer[previousRenderPixel]);
    return dot(currentNormal, previousNormal) > 0.72;
}

[numthreads(16, 16, 1)]
void TAA(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex,
    uint3 groupID : SV_GroupID
    )
{
    uint2 pixel = dispatchThreadID.xy;
    if (any(pixel >= (uint2)g_view.displayResolution))
        return;

    uint2 renderPixel = TAADisplayToRenderPixel(pixel);
    float3 current = TAALoadCurrentColor(int2(pixel));
    if (!TAAIsFinite(current))
        current = 0.0;

    float3 neighborhoodMin;
    float3 neighborhoodMax;
    float neighborMaxLuminance;
    TAAGetNeighborhood(
        pixel,
        neighborhoodMin,
        neighborhoodMax,
        neighborMaxLuminance);

    float emissionLuminance = getLuminance(
        max(inputEmissiveAndLinearRoughness[renderPixel].rgb, 0.0));
    current = TAAClampCurrentFirefly(
        current,
        neighborMaxLuminance,
        emissionLuminance);

    float2 motionPixels =
        inputBufferMotionVectors[renderPixel]
        * g_view.displayResolution;
    float2 previousDisplayCenter =
        (float2)pixel + 0.5 + motionPixels;

    float historyWeight;
    float3 history = TAALoadHistoryBilinear(
        previousDisplayCenter,
        historyWeight);
    bool historyValid =
        g_view.frameCount > 1u
        && historyWeight > 0.99
        && TAAHistoryGeometryValid(renderPixel, previousDisplayCenter);

    float currentDepth = inputBufferPrimaryPathLength[renderPixel];
    bool currentSky = currentDepth >= TAA_SKY_DISTANCE;
    history = TAAClipHistory(history, neighborhoodMin, neighborhoodMax);

    float currentLuminance = getLuminance(current);
    float historyLuminance = getLuminance(history);
    float relativeChange =
        abs(currentLuminance - historyLuminance)
        / max(max(currentLuminance, historyLuminance), 0.05);
    float reactiveAlpha = smoothstep(0.18, 0.85, relativeChange) * 0.70;
    reactiveAlpha = max(
        reactiveAlpha,
        smoothstep(0.25, 2.5, emissionLuminance) * 0.35);
    reactiveAlpha = max(
        reactiveAlpha,
        saturate(length(motionPixels) * 0.018));

    float baseAlpha = currentSky
        ? PERF_TAA_SKY_ALPHA
        : PERF_TAA_BASE_ALPHA;
    float alpha = max(baseAlpha, reactiveAlpha);
    alpha = max(alpha, 1.0 - PERF_TAA_MAX_BLEND);
    if (!historyValid)
        alpha = 1.0;

    float3 resolved = lerp(history, current, saturate(alpha));
    resolved = max(resolved, 0.0);

    outputBufferTAAHistory[pixel] = float4(resolved, 1.0);
    outputBufferFinal[pixel] = float4(resolved, 1.0);
}
