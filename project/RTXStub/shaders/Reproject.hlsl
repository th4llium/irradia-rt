#include "Include/Generated/Signature.hlsl"
#include "Include/DenoisingCommon.hlsl"

[numthreads(16, 16, 1)]
void Reproject(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    uint2 pixelPos = dispatchThreadID.xy;
    if (any(pixelPos >= g_view.renderResolution)) return;

    uint diffuseOutputIndex = (g_rootConstant0 >> 8) & 0xff;
    uint specularOutputIndex = (g_rootConstant0 >> 16) & 0xff;
    bool useVarianceWeightDiffuse = g_rootConstant0 & 1;
    bool useVarianceWeightSpecular = g_rootConstant0 & 2;

    float4 currentDiffuse = outputBufferIndirectDiffuse[pixelPos];
    float4 currentSpecular = outputBufferIndirectSpecular[pixelPos];
    float  currentDepth = inputBufferPrimaryPathLength[pixelPos];
    float2 encodedNormal = inputBufferNormal[pixelPos];
    float3 currentNormal = DecodeDenoiserNormal(encodedNormal);
    float currentRoughness = saturate(
        outputBufferEmissiveAndLinearRoughness[pixelPos].a);

    const float SKY_DISTANCE = 65000.0;
    if (currentDepth >= SKY_DISTANCE) {
        outputBufferHistoryLength[pixelPos] = float2(1.0 / 255.0, 1.0 / 255.0);
        RWTexture2D<float4> diffuseOutput = denoisingOutputs[diffuseOutputIndex];
        diffuseOutput[pixelPos] = currentDiffuse;
        RWTexture2D<float4> specularOutput = denoisingOutputs[specularOutputIndex];
        specularOutput[pixelPos] = currentSpecular;
        if (useVarianceWeightDiffuse)
            outputBufferDiffuseMoments[pixelPos] = float2(0, 0);
        if (useVarianceWeightSpecular)
            outputBufferSpecularMoments[pixelPos] = float2(0, 0);
        return;
    }

    float2 motionUv = inputBufferMotionVectors[pixelPos];
    float2 motionPixels = motionUv * float2(g_view.renderResolution);

    float2 currentPixelCenter = float2(pixelPos) + 0.5;
    float2 previousPixelPos = currentPixelCenter + motionPixels;

    float2 previousNdc = (previousPixelPos / float2(g_view.renderResolution)) * 2.0 - 1.0;
    previousNdc.y = -previousNdc.y;
    float4 expectedPreviousStevePosH = mul(
        float4(previousNdc, 0.5, 1.0), g_view.prevInvViewProj);
    float3 expectedPreviousRayDirection = normalize(
        expectedPreviousStevePosH.xyz / expectedPreviousStevePosH.w
        - g_view.previousViewOriginSteveSpace);
    float reprojectedPathLength = inputBufferReprojectedPathLength[pixelPos];
    float3 expectedPreviousPos = g_view.previousViewOriginSteveSpace
        + expectedPreviousRayDirection * reprojectedPathLength;
    int2 prevPixel = int2(floor(previousPixelPos));

    bool isValid = false;
    int2 bestPrevPixel = prevPixel;
    float bestDepthDiff = 1000.0;
    
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            int2 testPixel = prevPixel + int2(x, y);
            if (any(testPixel < 0) || any(testPixel >= int2(g_view.renderResolution))) continue;
            
            float2 testNormalEnc = previousPrimaryNormalBuffer[testPixel];
            float3 testNormal = DecodeDenoiserNormal(testNormalEnc);
            if (dot(currentNormal, testNormal) < 0.866) continue;
            
            float testDepth = previousPrimaryPathLengthBuffer[testPixel];
            if (testDepth >= SKY_DISTANCE)
                continue;
            
            float2 testPixelCenter = float2(testPixel) + 0.5;
            float2 testNdc = (testPixelCenter / float2(g_view.renderResolution)) * 2.0 - 1.0;
            testNdc.y = -testNdc.y;
            float4 testStevePosH = mul(float4(testNdc, 0.5, 1.0), g_view.prevInvViewProj);
            float3 testPos = g_view.previousViewOriginSteveSpace + normalize(testStevePosH.xyz / testStevePosH.w - g_view.previousViewOriginSteveSpace) * testDepth;
            
            float depthDiff = length(expectedPreviousPos - testPos);
            if (depthDiff > GetReprojectionDepthTolerance(reprojectedPathLength)) {
                continue;
            }
            if (depthDiff < bestDepthDiff) {
                bestDepthDiff = depthDiff;
                bestPrevPixel = testPixel;
                isValid = true;
            }
        }
    }
    
    prevPixel = bestPrevPixel;

    float historyLength = 1.0;
    float specularHistoryLength = 1.0;
    float3 prevDiffuse = 0;
    float3 prevSpecular = 0;
    float2 prevDiffuseMoments = 0;
    float2 prevSpecularMoments = 0;
    bool disoccludedThisFrame = false;

    if (isValid) {
        prevDiffuse = previousDiffuseBuffer[prevPixel].rgb;
        prevSpecular = previousSpecularBuffer[prevPixel].rgb;
        
        float2 prevHistoryLengths = previousHistoryLengthBuffer[prevPixel] * 255.0;
        historyLength = prevHistoryLengths.x + 1.0;
        specularHistoryLength = prevHistoryLengths.y + 1.0;

#ifdef DISABLE_TEMPORAL_ACCUMULATION
        historyLength = 1.0;
        specularHistoryLength = 1.0;
        disoccludedThisFrame = true;
#endif

        historyLength = min(
            historyLength,
            PERF_DIFFUSE_TEMPORAL_MAX_HISTORY);
        prevDiffuse = ClipDiffuseHistory(
            int2(pixelPos),
            prevDiffuse,
            currentDepth,
            currentNormal);
        float previousRoughness = previousLinearRoughnessBuffer[prevPixel];
        float roughnessTolerance = lerp(0.04, 0.16, currentRoughness);
        bool specularHistoryValid =
            abs(previousRoughness - currentRoughness) <= roughnessTolerance;
        if (specularHistoryValid) {
            float maxSpecularHistory = lerp(3.0, 8.0, currentRoughness);
            specularHistoryLength = min(
                specularHistoryLength,
                maxSpecularHistory);
            prevSpecular = ClipSpecularHistory(
                int2(pixelPos),
                prevSpecular,
                currentDepth,
                currentNormal);
        } else {
            specularHistoryLength = 1.0;
            prevSpecular = 0.0;
            prevSpecularMoments = 0.0;
        }

        if (useVarianceWeightDiffuse)
            prevDiffuseMoments = inputBufferOrFinalDiffuseMoments[prevPixel];
        if (useVarianceWeightSpecular)
            prevSpecularMoments = inputBufferOrFinalSpecularMoments[prevPixel];
    } else {
        disoccludedThisFrame = true;
    }


    historyLength = min(
        historyLength,
        PERF_DIFFUSE_TEMPORAL_MAX_HISTORY);
    float diffuseAlpha = max(
        1.0 / historyLength,
        PERF_DIFFUSE_TEMPORAL_MIN_ALPHA);
    float3 blendedDiffuse = lerp(prevDiffuse, currentDiffuse.rgb, diffuseAlpha);

    float diffuseLum = getLuminance(currentDiffuse.rgb);
    float2 diffuseMoments;
    diffuseMoments.x = diffuseLum;
    diffuseMoments.y = diffuseLum * diffuseLum;
    diffuseMoments = lerp(prevDiffuseMoments, diffuseMoments, diffuseAlpha);
    float diffuseVariance = max(0.0, diffuseMoments.y - diffuseMoments.x * diffuseMoments.x);
    
    if (disoccludedThisFrame) {
        diffuseVariance += 1000000.0;
    } else if (historyLength < 4.0) {
        diffuseVariance += 0.5 * (4.0 - historyLength);
    }

    float minimumSpecularAlpha = lerp(0.28, 0.12, currentRoughness);
    float specularAlpha = max(
        1.0 / max(specularHistoryLength, 1.0),
        max(g_view.specularTemporalAlpha, minimumSpecularAlpha));
    float3 blendedSpecular = lerp(
        prevSpecular,
        currentSpecular.rgb,
        specularAlpha);

    float specularLum = getLuminance(currentSpecular.rgb);
    float2 specularMoments;
    specularMoments.x = specularLum;
    specularMoments.y = specularLum * specularLum;
    specularMoments = lerp(prevSpecularMoments, specularMoments, specularAlpha);
    float specularVariance = max(0.0, specularMoments.y - specularMoments.x * specularMoments.x);
    
    if (disoccludedThisFrame) {
        specularVariance += 1000000.0;
    } else if (specularHistoryLength < 4.0) {
        specularVariance += 0.5 * (4.0 - specularHistoryLength);
    }

    RWTexture2D<float4> diffuseOutput = denoisingOutputs[diffuseOutputIndex];
    diffuseOutput[pixelPos] = float4(blendedDiffuse, diffuseVariance);

    RWTexture2D<float4> specularOutput = denoisingOutputs[specularOutputIndex];
    specularOutput[pixelPos] = float4(blendedSpecular, specularVariance);

    outputBufferHistoryLength[pixelPos] = float2(historyLength, specularHistoryLength) * (1.0 / 255.0);

    if (useVarianceWeightDiffuse)
        outputBufferDiffuseMoments[pixelPos] = diffuseMoments;
    if (useVarianceWeightSpecular)
        outputBufferSpecularMoments[pixelPos] = specularMoments;
}
