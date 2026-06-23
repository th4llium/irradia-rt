#ifndef __DENOISING_COMMON_HLSL__
#define __DENOISING_COMMON_HLSL__

#include "Util.hlsl"

float3 DecodeDenoiserNormal(float2 encoded)
{
    float3 normal = float3(
        encoded,
        1.0 - abs(encoded.x) - abs(encoded.y));
    if (normal.z < 0.0)
        normal.xy = (1.0 - abs(normal.yx))
            * select(normal.xy >= 0.0, 1.0, -1.0);
    return normalize(normal);
}

float GetReprojectionDepthTolerance(float pathLength)
{
    return 0.08 + min(max(pathLength, 0.0) * 0.005, 0.35);
}

float FireflyMeasure(float3 signal, bool vectorSignal)
{
    return vectorSignal ? length(signal) : getLuminance(signal);
}

float4 ClampFirefly(
    Texture2D<float4> inputSignal,
    int2 pixel,
    bool vectorSignal,
    float sigmaScale,
    float relativeEpsilon)
{
    float4 center = inputSignal[pixel];
    float centerDepth = inputBufferPrimaryPathLength[pixel];
    if (centerDepth >= 65000.0)
        return center;

    float3 centerNormal = DecodeDenoiserNormal(inputBufferNormal[pixel]);
    float sum = 0.0;
    float sumSquared = 0.0;
    float sampleCount = 0.0;
    int2 renderSize = int2(g_view.renderResolution);

    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            if (x == 0 && y == 0)
                continue;

            int2 samplePixel = pixel + int2(x, y);
            if (any(samplePixel < 0) || any(samplePixel >= renderSize))
                continue;

            float sampleDepth = inputBufferPrimaryPathLength[samplePixel];
            float depthDelta =
                abs(sampleDepth - centerDepth) / max(centerDepth, 0.001);
            float3 sampleNormal =
                DecodeDenoiserNormal(inputBufferNormal[samplePixel]);
            if (depthDelta > 0.04 || dot(centerNormal, sampleNormal) < 0.8)
                continue;

            float measure =
                FireflyMeasure(inputSignal[samplePixel].rgb, vectorSignal);
            sum += measure;
            sumSquared += measure * measure;
            sampleCount += 1.0;
        }
    }

    if (sampleCount < 3.0)
        return center;

    float mean = sum / sampleCount;
    float variance = max(sumSquared / sampleCount - mean * mean, 0.0);
    float upperBound = mean
        + sigmaScale * sqrt(variance)
        + relativeEpsilon * max(mean, 0.01);
    float centerMeasure = FireflyMeasure(center.rgb, vectorSignal);
    if (centerMeasure > upperBound)
        center.rgb *= upperBound / max(centerMeasure, 0.0001);
    return center;
}

float3 ClipSpecularHistory(
    int2 pixel,
    float3 history,
    float depth,
    float3 normal)
{
    float3 neighborhoodMin = outputBufferIndirectSpecular[pixel].rgb;
    float3 neighborhoodMax = neighborhoodMin;
    int2 renderSize = int2(g_view.renderResolution);

    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            int2 samplePixel = pixel + int2(x, y);
            if (any(samplePixel < 0) || any(samplePixel >= renderSize))
                continue;

            float sampleDepth = inputBufferPrimaryPathLength[samplePixel];
            float depthDelta = abs(sampleDepth - depth) / max(depth, 0.001);
            float3 sampleNormal =
                DecodeDenoiserNormal(inputBufferNormal[samplePixel]);
            if (depthDelta > 0.05 || dot(normal, sampleNormal) < 0.75)
                continue;

            float3 sample = outputBufferIndirectSpecular[samplePixel].rgb;
            neighborhoodMin = min(neighborhoodMin, sample);
            neighborhoodMax = max(neighborhoodMax, sample);
        }
    }

    float3 range = neighborhoodMax - neighborhoodMin;
    float3 margin = range * 0.35
        + max(neighborhoodMax * 0.08, (0.01).xxx);
    return clamp(history, neighborhoodMin - margin, neighborhoodMax + margin);
}

float AtrousNormalWeight(float3 center, float3 sample, float exponent)
{
    return pow(saturate(dot(center, sample)), exponent);
}

float AtrousLuminanceWeight(float center, float sample, float sigma)
{
    return exp(-abs(center - sample) / max(sigma, 1.0e-6));
}

float AtrousDepthWeight(float center, float sample)
{
    float depthDelta = abs(center - sample);
    float relativeDepth = depthDelta / max(center, 0.001);
    return exp(-relativeDepth * 64.0 - depthDelta * 0.75);
}

void FilterAtrousPixel(int2 pixel)
{
    uint inputIndex = g_rootConstant0 & 0xff;
    uint outputIndex = (g_rootConstant0 >> 8) & 0xff;
    uint iteration = (g_rootConstant0 >> 16) & 0xff;
    uint paramsIndex = (g_rootConstant0 >> 24) % 2;
    bool useVariance = (g_rootConstant0 >> 26) & 1;

    Texture2D<float4> inputSignal = denoisingInputs[inputIndex];
    RWTexture2D<float4> outputSignal = denoisingOutputs[outputIndex];

    float depth = inputBufferPrimaryPathLength[pixel];
    if (depth >= 65000.0)
        return;

    float4 center = inputSignal[pixel];
    float3 centerNormal = DecodeDenoiserNormal(inputBufferNormal[pixel]);
    float centerLuminance = getLuminance(center.rgb);
    float centerVariance = center.a;
    float normalExponent = 128.0;
    float luminanceSigma = 4.0;

    float historyLength = outputBufferHistoryLength[pixel][
        paramsIndex == 1 ? 1 : 0] * 255.0;
    if (historyLength < 4.0)
        normalExponent = max(
            4.0,
            normalExponent * min(historyLength * 0.25, 1.0));

    if (paramsIndex == 1)
    {
        float roughness = saturate(
            outputBufferEmissiveAndLinearRoughness[pixel].a);
        luminanceSigma = lerp(1.0, 3.0, roughness * roughness);
        normalExponent = lerp(256.0, 96.0, roughness);
    }

    if (useVariance)
        luminanceSigma *= sqrt(max(abs(centerVariance), 1.0e-10));

    static const float kernel[2] = { 1.0, 0.5 };
    int stepSize = (int)(1u << iteration);
    int2 renderSize = int2(g_view.renderResolution);
    float weightSum = 1.0;
    float4 signalSum = center;
    float varianceSum = centerVariance;

    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            if (x == 0 && y == 0)
                continue;

            int2 samplePixel = pixel + int2(x, y) * stepSize;
            if (any(samplePixel < 0) || any(samplePixel >= renderSize))
                continue;

            float weight = kernel[abs(x)] * kernel[abs(y)];
            float3 sampleNormal =
                DecodeDenoiserNormal(inputBufferNormal[samplePixel]);
            weight *= AtrousNormalWeight(
                centerNormal, sampleNormal, normalExponent);

            float sampleDepth = inputBufferPrimaryPathLength[samplePixel];
            weight *= AtrousDepthWeight(depth, sampleDepth);

            float4 sample = inputSignal[samplePixel];
            weight *= AtrousLuminanceWeight(
                centerLuminance,
                getLuminance(sample.rgb),
                luminanceSigma);

            weightSum += weight;
            signalSum += sample * weight;
            varianceSum += sample.a * weight * weight;
        }
    }

    float3 filteredSignal = signalSum.rgb / weightSum;
    float filteredVariance = varianceSum / (weightSum * weightSum);
    outputSignal[pixel] = float4(filteredSignal, filteredVariance);
}

void FilterMomentPixel(int2 pixel)
{
    uint inputIndex = (g_rootConstant0 >> 16) & 0xff;
    uint outputIndex = (g_rootConstant0 >> 8) & 0xff;
    Texture2D<float2> inputMoments = denoisingMomentsInputs[inputIndex];
    float2 centerMoments = inputMoments[pixel];

    float depth = inputBufferPrimaryPathLength[pixel];
    float historyLength = outputBufferHistoryLength[pixel].x * 255.0;
    if (historyLength >= 4.0 || depth >= 65000.0)
    {
        outputDenoisingMoments[outputIndex][pixel] = centerMoments;
        return;
    }

    float3 centerNormal = DecodeDenoiserNormal(inputBufferNormal[pixel]);
    float weightSum = 1.0;
    float2 momentSum = centerMoments;
    int2 renderSize = int2(g_view.renderResolution);

    [unroll]
    for (int y = -2; y <= 2; ++y)
    {
        [unroll]
        for (int x = -2; x <= 2; ++x)
        {
            if (x == 0 && y == 0)
                continue;

            int2 samplePixel = pixel + int2(x, y);
            if (any(samplePixel < 0) || any(samplePixel >= renderSize))
                continue;

            float3 sampleNormal =
                DecodeDenoiserNormal(inputBufferNormal[samplePixel]);
            float weight = pow(
                saturate(dot(centerNormal, sampleNormal)), 128.0);
            float sampleDepth = inputBufferPrimaryPathLength[samplePixel];
            float relativeDepth =
                abs(depth - sampleDepth) / max(depth, 0.001);
            weight *= exp(-relativeDepth * 10.0);

            weightSum += weight;
            momentSum += inputMoments[samplePixel] * weight;
        }
    }

    outputDenoisingMoments[outputIndex][pixel] =
        momentSum / weightSum;
}

#endif
