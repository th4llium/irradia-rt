/* MIT License
 * 
 * Copyright (c) 2025 veka0
 * Copyright (c) 2026 th4llium
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#ifndef __DEBUG_HLSL__
#define __DEBUG_HLSL__

#include "Generated/Signature.hlsl"

template<typename T>
float SampleBuffer(RWTexture2D<T> tex) { return (float)tex[uint2(0,0)]; }
template<typename T>
float SampleBuffer(RWTexture3D<T> tex) { return (float)tex[uint3(0,0,0)]; }
template<typename T>
float SampleBuffer(Texture2D<T> tex) { return (float)tex[uint2(0,0)]; }
template<typename T>
float SampleBuffer(Texture3D<T> tex) { return (float)tex[uint3(0,0,0)]; }
template<typename T>
float SampleBuffer(StructuredBuffer<T> tex) { return (float)tex[0]; }
template<typename T>
float SampleBuffer(RWStructuredBuffer<T> tex) { return (float)tex[0]; }
template<typename T>
float SampleBuffer(Texture2DArray<T> tex) { return (float)tex[uint3(0,0,0)]; }

void SimulateBufferReads() {
    if (g_view.time != -1) return;

    float readbackAccumulator = 0;

    readbackAccumulator += SampleBuffer(outputBufferPrimaryPathLength);
    readbackAccumulator += SampleBuffer(outputBufferNormal);
    readbackAccumulator += SampleBuffer(outputBufferHistoryLength);
    readbackAccumulator += SampleBuffer(outputBufferColourAndMetallic);
    readbackAccumulator += SampleBuffer(outputBufferEmissiveAndLinearRoughness);
    readbackAccumulator += SampleBuffer(outputBufferIndirectDiffuse);
    readbackAccumulator += SampleBuffer(outputBufferIndirectSpecular);
    readbackAccumulator += SampleBuffer(outputBufferSurfaceOpacityAndObjectCategory);
    readbackAccumulator += SampleBuffer(outputBufferMotionVectors);
    readbackAccumulator += SampleBuffer(outputBufferIncomingIrradianceCache);
    readbackAccumulator += SampleBuffer(outputBufferFinal);
    readbackAccumulator += SampleBuffer(outputBufferDirectLightTransmission);
    readbackAccumulator += SampleBuffer(outputBufferDebug);
    readbackAccumulator += SampleBuffer(outputBufferReflectionDistance);
    readbackAccumulator += SampleBuffer(outputBufferReflectionMotionVectors);
    readbackAccumulator += SampleBuffer(outputBufferPreviousLinearRoughness);
    readbackAccumulator += SampleBuffer(outputBufferPreInterleave);
    readbackAccumulator += SampleBuffer(outputPlaneIdentifier);
    readbackAccumulator += SampleBuffer(outputBufferReprojectedPathLength);
    readbackAccumulator += SampleBuffer(outputBufferSunLightShadow);
    readbackAccumulator += SampleBuffer(outputBufferPreviousSunLightShadow);
    readbackAccumulator += SampleBuffer(outputBufferReferencePathTracer);
    readbackAccumulator += SampleBuffer(outputBufferRayDirection);
    readbackAccumulator += SampleBuffer(outputBufferRayThroughput);
    readbackAccumulator += SampleBuffer(outputBufferToneMappingHistogram);
    readbackAccumulator += SampleBuffer(outputBufferToneCurve);
    readbackAccumulator += SampleBuffer(outputBufferIndirectDiffuseChroma);
    readbackAccumulator += SampleBuffer(outputBufferPrimaryPosLowPrecision);
    readbackAccumulator += SampleBuffer(outputBufferTAAHistory);
    readbackAccumulator += SampleBuffer(outputGeometryNormal);
    readbackAccumulator += SampleBuffer(outputVisibleBLASs);
    readbackAccumulator += SampleBuffer(outputPrimaryWorldPosition);
    readbackAccumulator += SampleBuffer(outputPrimaryViewDirection);
    readbackAccumulator += SampleBuffer(outputPrimaryThroughput);
    readbackAccumulator += SampleBuffer(outputAdaptiveDenoiserGradients[0]);
    readbackAccumulator += SampleBuffer(outputAdaptiveDenoiserGradients[1]);
    readbackAccumulator += SampleBuffer(outputAdaptiveDenoiserReference);
    readbackAccumulator += SampleBuffer(outputAdaptiveDenoiserPlaneIdentifier);
    readbackAccumulator += SampleBuffer(outputBufferDiffuseMoments);
    readbackAccumulator += SampleBuffer(outputFinalDiffuseMoments);
    readbackAccumulator += SampleBuffer(outputBufferSpecularMoments);
    readbackAccumulator += SampleBuffer(outputFinalSpecularMoments);
    readbackAccumulator += SampleBuffer(outputTileClassification);
    readbackAccumulator += SampleBuffer(outputBufferPreviousMedium);
    readbackAccumulator += SampleBuffer(objectInstances);
    readbackAccumulator += SampleBuffer(vertexIrradianceCacheUpdateChunks);
    readbackAccumulator += SampleBuffer(faceIrradianceCacheUpdateChunks);
    readbackAccumulator += SampleBuffer(previousPrimaryPathLengthBuffer);
    readbackAccumulator += SampleBuffer(previousPrimaryNormalBuffer);
    readbackAccumulator += SampleBuffer(previousHistoryLengthBuffer);
    readbackAccumulator += SampleBuffer(previousDiffuseBuffer);
    readbackAccumulator += SampleBuffer(previousSpecularBuffer);
    readbackAccumulator += SampleBuffer(inputBufferOrFinalDiffuseMoments);
    readbackAccumulator += SampleBuffer(inputBufferOrFinalSpecularMoments);
    readbackAccumulator += SampleBuffer(volumetricResolvedInscatter);
    readbackAccumulator += SampleBuffer(volumetricResolvedTransmission);
    readbackAccumulator += SampleBuffer(volumetricInscatterPrevious);
    readbackAccumulator += SampleBuffer(inputBufferPrimaryPathLength);
    readbackAccumulator += SampleBuffer(inputBufferNormal);
    readbackAccumulator += SampleBuffer(inputBufferColourAndMetallic);
    readbackAccumulator += SampleBuffer(inputBufferSurfaceOpacityAndObjectCategory);
    readbackAccumulator += SampleBuffer(inputBufferIncomingIrradianceCache);
    readbackAccumulator += SampleBuffer(inputIncidentLight);
    readbackAccumulator += SampleBuffer(inputDirectLightTransmission);
    readbackAccumulator += SampleBuffer(inputBufferMotionVectors);
    readbackAccumulator += SampleBuffer(inputBufferReflectionMotionVectors);
    readbackAccumulator += SampleBuffer(previousReflectionDistanceBuffer);
    readbackAccumulator += SampleBuffer(previousLinearRoughnessBuffer);
    readbackAccumulator += SampleBuffer(inputBufferPreInterleaveCurrent);
    readbackAccumulator += SampleBuffer(inputBufferPreInterleavePrevious);
    readbackAccumulator += SampleBuffer(inputPlaneIdentifier);
    readbackAccumulator += SampleBuffer(inputBufferReprojectedPathLength);
    readbackAccumulator += SampleBuffer(previousSunLightShadowBuffer);
    readbackAccumulator += SampleBuffer(referencePathTracerBuffer);
    readbackAccumulator += SampleBuffer(pbrTextureDataBuffer);
    readbackAccumulator += SampleBuffer(inputBufferToneMappingHistogram);
    readbackAccumulator += SampleBuffer(inputBufferToneCurve);
    readbackAccumulator += SampleBuffer(volumetricGIResolvedInscatter);
    readbackAccumulator += SampleBuffer(volumetricGIInscatterPrevious);
    readbackAccumulator += SampleBuffer(inputTAAHistory);
    readbackAccumulator += SampleBuffer(inputThisFrameTAAHistory);
    readbackAccumulator += SampleBuffer(inputFinalColour);
    readbackAccumulator += SampleBuffer(inputGeometryNormal);
    readbackAccumulator += SampleBuffer(inputEmissiveAndLinearRoughness);
    readbackAccumulator += SampleBuffer(inputPrimaryWorldPosition);
    readbackAccumulator += SampleBuffer(inputPrimaryViewDirection);
    readbackAccumulator += SampleBuffer(inputPrimaryThroughput);
    readbackAccumulator += SampleBuffer(previousDiffuseChromaBuffer);
    readbackAccumulator += SampleBuffer(inputPreviousGeometryNormal);
    readbackAccumulator += SampleBuffer(inputPrimaryPosLowPrecision);
    readbackAccumulator += SampleBuffer(inputAdaptiveDenoiserGradients[0]);
    readbackAccumulator += SampleBuffer(inputAdaptiveDenoiserGradients[1]);
    readbackAccumulator += SampleBuffer(inputAdaptiveDenoiserReference);
    readbackAccumulator += SampleBuffer(inputAdaptiveDenoiserPlaneIdentifier);
    readbackAccumulator += SampleBuffer(checkerboardActionsBuffer);
    readbackAccumulator += SampleBuffer(refractionIndicesBuffer);
    readbackAccumulator += SampleBuffer(inputTileClassification);
    readbackAccumulator += SampleBuffer(blueNoiseTexture);
    readbackAccumulator += SampleBuffer(skyTexture);
    readbackAccumulator += SampleBuffer(causticsTexture);
    readbackAccumulator += SampleBuffer(wibblyTexture);
    readbackAccumulator += SampleBuffer(waterNormalsTexture);
    readbackAccumulator += SampleBuffer(inputBufferPreviousMedium);
    readbackAccumulator += SampleBuffer(bufferIncidentLight);
    readbackAccumulator += SampleBuffer(volumetricResolvedInscatterRW);
    readbackAccumulator += SampleBuffer(volumetricResolvedTransmissionRW);
    readbackAccumulator += SampleBuffer(volumetricInscatterRW);
    readbackAccumulator += SampleBuffer(volumetricGIResolvedInscatterRW);
    readbackAccumulator += SampleBuffer(volumetricGIInscatterRW[0]);
    readbackAccumulator += SampleBuffer(volumetricGIInscatterRW[1]);
    readbackAccumulator += SampleBuffer(denoisingInputs[0]);
    readbackAccumulator += SampleBuffer(denoisingInputs[1]);
    readbackAccumulator += SampleBuffer(denoisingInputs[2]);
    readbackAccumulator += SampleBuffer(denoisingInputs[3]);
    readbackAccumulator += SampleBuffer(denoisingInputs[4]);
    readbackAccumulator += SampleBuffer(denoisingInputs[5]);
    readbackAccumulator += SampleBuffer(denoisingInputs[6]);
    readbackAccumulator += SampleBuffer(denoisingInputs[7]);
    readbackAccumulator += SampleBuffer(denoisingChromaAndVarianceInputs[0]);
    readbackAccumulator += SampleBuffer(denoisingChromaAndVarianceInputs[1]);
    readbackAccumulator += SampleBuffer(denoisingChromaAndVarianceInputs[2]);
    readbackAccumulator += SampleBuffer(denoisingChromaAndVarianceInputs[3]);
    readbackAccumulator += SampleBuffer(denoisingOutputs[0]);
    readbackAccumulator += SampleBuffer(denoisingOutputs[1]);
    readbackAccumulator += SampleBuffer(denoisingOutputs[2]);
    readbackAccumulator += SampleBuffer(denoisingOutputs[3]);
    readbackAccumulator += SampleBuffer(denoisingOutputs[4]);
    readbackAccumulator += SampleBuffer(denoisingOutputs[5]);
    readbackAccumulator += SampleBuffer(denoisingOutputs[6]);
    readbackAccumulator += SampleBuffer(denoisingOutputs[7]);
    readbackAccumulator += SampleBuffer(denoisingChromaAndVarianceOutputs[0]);
    readbackAccumulator += SampleBuffer(denoisingChromaAndVarianceOutputs[1]);
    readbackAccumulator += SampleBuffer(denoisingChromaAndVarianceOutputs[2]);
    readbackAccumulator += SampleBuffer(denoisingChromaAndVarianceOutputs[3]);
    readbackAccumulator += SampleBuffer(inputBufferDiffuseMoments);
    readbackAccumulator += SampleBuffer(inputFinalDiffuseMoments);
    readbackAccumulator += SampleBuffer(inputBufferSpecularMoments);
    readbackAccumulator += SampleBuffer(inputFinalSpecularMoments);
    readbackAccumulator += SampleBuffer(shadowDenoisingInputs[0]);
    readbackAccumulator += SampleBuffer(shadowDenoisingInputs[1]);
    readbackAccumulator += SampleBuffer(shadowDenoisingOutputs[0]);
    readbackAccumulator += SampleBuffer(shadowDenoisingOutputs[1]);
    readbackAccumulator += SampleBuffer(outputLightsBuffer);
    readbackAccumulator += SampleBuffer(outputReducedLightsBuffer);
    readbackAccumulator += SampleBuffer(inputLightsBuffer);
    readbackAccumulator += SampleBuffer(inputReducedLightsBuffer);
    readbackAccumulator += SampleBuffer(inputTemporallyStableLights);

    outputBufferFinal[uint2(0, 0)] = readbackAccumulator;
}
#endif
