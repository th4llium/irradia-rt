#include "Include/Generated/Signature.hlsl"
#include "Include/DenoisingCommon.hlsl"

[numthreads(16, 16, 1)]
void ReprojectSH(
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

    float2 posPreviousPixelsCornered = previousPixelPos - 0.5;
    int2 bilinearSamplingCornerPos = int2(floor(posPreviousPixelsCornered));
    float2 bilinearWeights = frac(posPreviousPixelsCornered);

    float totalWeight = 0.0;
    float historyLength = 0.0;
    float specularHistoryLength = 0.0;
    float3 prevDiffuse = 0;
    float3 prevSpecular = 0;
    float2 prevDiffuseMoments = 0;
    float2 prevSpecularMoments = 0;
    bool disoccludedThisFrame = true;

    for (int sampleIdx = 0; sampleIdx < 4; sampleIdx++) {
        int2 sampleOffset = int2(sampleIdx & 1, (sampleIdx >> 1) & 1);
        int2 testPixel = bilinearSamplingCornerPos + sampleOffset;

        float2 weights = lerp(1.0 - bilinearWeights, bilinearWeights, float2(sampleOffset));
        float sampleWeight = weights.x * weights.y;

        if (any(testPixel < 0) || any(testPixel >= int2(g_view.renderResolution))) {
            sampleWeight = 0.0;
        } else {
            float2 testNormalEnc = previousPrimaryNormalBuffer[testPixel];
            float3 testNormal = DecodeDenoiserNormal(testNormalEnc);
            float normalMatch = dot(currentNormal, testNormal);
            sampleWeight *= saturate((normalMatch - 0.8) / (0.95 - 0.8));

            float testDepth = previousPrimaryPathLengthBuffer[testPixel];
            if (testDepth >= SKY_DISTANCE)
                sampleWeight = 0.0;
            
            float2 testPixelCenter = float2(testPixel) + 0.5;
            float2 testNdc = (testPixelCenter / float2(g_view.renderResolution)) * 2.0 - 1.0;
            testNdc.y = -testNdc.y;
            float4 testStevePosH = mul(float4(testNdc, 0.5, 1.0), g_view.prevInvViewProj);
            float3 testPos = g_view.previousViewOriginSteveSpace + normalize(testStevePosH.xyz / testStevePosH.w - g_view.previousViewOriginSteveSpace) * testDepth;
            
            float depthDiff = length(expectedPreviousPos - testPos);
            if (depthDiff > GetReprojectionDepthTolerance(reprojectedPathLength)) {
                sampleWeight = 0.0;
            }
        }

#ifdef DISABLE_TEMPORAL_ACCUMULATION
        sampleWeight = 0.0;
#endif

        if (sampleWeight > 0.0) {
            prevDiffuse += previousDiffuseBuffer[testPixel].rgb * sampleWeight;
            prevSpecular += previousSpecularBuffer[testPixel].rgb * sampleWeight;
            
            float2 prevHistoryLengths = previousHistoryLengthBuffer[testPixel] * 255.0;
            historyLength += (prevHistoryLengths.x + 1.0) * sampleWeight;
            specularHistoryLength += (prevHistoryLengths.y + 1.0) * sampleWeight;

            if (useVarianceWeightDiffuse)
                prevDiffuseMoments += inputBufferOrFinalDiffuseMoments[testPixel] * sampleWeight;
            if (useVarianceWeightSpecular)
                prevSpecularMoments += inputBufferOrFinalSpecularMoments[testPixel] * sampleWeight;
            
            totalWeight += sampleWeight;
            disoccludedThisFrame = false;
        }
    }

    if (totalWeight > 0.0) {
        float recipTotalWeight = 1.0 / totalWeight;
        prevDiffuse *= recipTotalWeight;
        prevSpecular *= recipTotalWeight;
        historyLength *= recipTotalWeight;
        specularHistoryLength *= recipTotalWeight;
        prevDiffuseMoments *= recipTotalWeight;
        prevSpecularMoments *= recipTotalWeight;


        historyLength = min(historyLength, 16.0);
        int2 roughnessPixel = clamp(
            int2(round(previousPixelPos - 0.5)),
            int2(0, 0),
            int2(g_view.renderResolution) - 1);
        float previousRoughness =
            previousLinearRoughnessBuffer[roughnessPixel];
        float roughnessTolerance = lerp(0.04, 0.16, currentRoughness);
        if (abs(previousRoughness - currentRoughness)
            <= roughnessTolerance)
        {
            specularHistoryLength = min(
                specularHistoryLength,
                lerp(3.0, 8.0, currentRoughness));
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
    } else {
        historyLength = 1.0;
        specularHistoryLength = 1.0;
        disoccludedThisFrame = true;
    }



    float diffuseAlpha = max(1.0 / historyLength, 0.1);
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
        float additionalVariance = exp2((1.0 / historyLength) * 12.0 + 1.0);
        additionalVariance -= exp2((1.0 / 5.0) * 12.0 + 1.0);
        diffuseVariance += max(additionalVariance, 0.0);
    }

    float minimumSpecularAlpha = lerp(0.28, 0.12, currentRoughness);
    float specularAlpha = max(
        1.0 / max(specularHistoryLength, 1.0),
        max(g_view.specularTemporalAlpha, minimumSpecularAlpha));
    float3 blendedSpecular = lerp(
        prevSpecular,
        currentSpecular.rgb,
        specularAlpha);

    float specLum = getLuminance(currentSpecular.rgb);
    float2 specularMoments;
    specularMoments.x = specLum;
    specularMoments.y = specLum * specLum;
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
