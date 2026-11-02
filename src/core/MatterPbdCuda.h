#pragma once
#include "PhysicsCuda.h"
namespace lab {
// All state is resident on the same CUDA device as PhysX and OpenXR/DX12.
void MatterInitialize(cudaStream_t stream, physx::PxVec4* positions,
    physx::PxVec4* velocities, physx::PxU32* phases,
    float* moisture, float* temperature, uint32_t count, uint32_t side,
    physx::PxVec3 center, float radius, float invMass, uint32_t wetPhase);
void MatterEvolve(cudaStream_t stream, const physx::PxVec4* positions,
    const physx::PxVec4* velocities, physx::PxU32* phases,
    float* moisture, float* temperature, uint32_t count, uint32_t wetPhase,
    uint32_t dryPhase, const PhysicsLightGpu* lights, uint32_t lightCount,
    const physx::PxTransform* poses, const PhysicsAirflowGpu* airflows,
    uint32_t airflowCount, const physx::PxVec3* angular, float dt, float time);
void MatterPack(cudaStream_t stream, const physx::PxVec4* positions,
    const float* moisture, uint32_t count, uint32_t base, float radius,
    uint32_t mesh, uint32_t material, bool visible, GpuInstance* instances,
    uint32_t* control);
}
