#ifndef __CLOUD_WORLD_POSITION_HLSL__
#define __CLOUD_WORLD_POSITION_HLSL__

#include "Generated/Signature.hlsl"

static const float CLOUD_WORLD_VALID_MARKER = 42137.0;
static const float CLOUD_WORLD_TILE_SIZE = 1024.0;

bool CloudWorldIsFinite(float value)
{
    return !isnan(value) && !isinf(value);
}

bool CloudWorldIsFinite(float3 value)
{
    return !any(isnan(value)) && !any(isinf(value));
}

float3 CloudUnwrapTiledDelta(float3 delta)
{
    return delta - round(delta / CLOUD_WORLD_TILE_SIZE) * CLOUD_WORLD_TILE_SIZE;
}

float3 GetCloudCameraDeltaEstimate()
{
    float3 worldDelta = g_view.previousToCurrentCameraPosWorldSpace;
    float3 steveDelta =
        CloudUnwrapTiledDelta(
            g_view.viewOriginSteveSpace
            - g_view.previousViewOriginSteveSpace);
    float3 providedSteveDelta =
        CloudUnwrapTiledDelta(g_view.previousToCurrentCameraPosSteveSpace);

    float steveLen = length(steveDelta);
    float providedSteveLen = length(providedSteveDelta);
    if (providedSteveLen > steveLen)
    {
        steveDelta = providedSteveDelta;
        steveLen = providedSteveLen;
    }

    float worldLen = length(worldDelta);
    bool useSteveDelta =
        !CloudWorldIsFinite(worldDelta)
        || worldLen > 256.0
        || (worldLen < 1.0e-5 && steveLen > 1.0e-4)
        || (worldLen > 1.0e-4
            && steveLen > 1.0e-4
            && abs(worldLen - steveLen) > max(4.0, steveLen * 2.0));

    return useSteveDelta ? steveDelta : worldDelta;
}

float3 LoadCloudCameraWorldOrigin()
{
    float4 incidentHeader0 = inputIncidentLight[0];
    float4 incidentHeader1 = inputIncidentLight[1];
    float4 state = float4(
        incidentHeader0.b,
        incidentHeader0.a,
        incidentHeader1.b,
        incidentHeader1.a);
    bool valid =
        abs(state.w - CLOUD_WORLD_VALID_MARKER) < 0.5
        && CloudWorldIsFinite(state.xyz);

    return valid ? state.xyz : g_view.viewOriginSteveSpace;
}

float3 GetCloudStableWorldPosition(float3 steveSpacePosition)
{
    return steveSpacePosition
        - g_view.viewOriginSteveSpace
        + LoadCloudCameraWorldOrigin();
}

void StoreCloudCameraWorldOriginEstimate()
{
    float4 incidentHeader0 = bufferIncidentLight[0];
    float4 incidentHeader1 = bufferIncidentLight[1];
    float4 previousState = float4(
        incidentHeader0.b,
        incidentHeader0.a,
        incidentHeader1.b,
        incidentHeader1.a);
    bool previousValid =
        abs(previousState.w - CLOUD_WORLD_VALID_MARKER) < 0.5
        && CloudWorldIsFinite(previousState.xyz);

    float3 cameraDelta = GetCloudCameraDeltaEstimate();
    bool deltaValid =
        CloudWorldIsFinite(cameraDelta)
        && length(cameraDelta) < 256.0;

    bool canAccumulate =
        previousValid
        && deltaValid
        && g_view.numFramesSinceTeleport > 1u;

    float3 cameraWorldOrigin =
        canAccumulate
            ? previousState.xyz + cameraDelta
            : g_view.viewOriginSteveSpace;

    incidentHeader0.ba = cameraWorldOrigin.xy;
    incidentHeader1.ba =
        float2(cameraWorldOrigin.z, CLOUD_WORLD_VALID_MARKER);
    bufferIncidentLight[0] = incidentHeader0;
    bufferIncidentLight[1] = incidentHeader1;
}

#endif
