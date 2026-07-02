[numthreads(4, 8, 1)]
void ExplicitLightSamplingInline(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex,
    uint3 groupID : SV_GroupID
    )
{
}
