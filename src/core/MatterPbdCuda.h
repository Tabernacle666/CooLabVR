#pragma once
#include "PhysicsCuda.h"
namespace lab {
struct MatterDiagnosticsGpu {
    int lower[3],upper[3];
    uint32_t wet,dry,hot,tableContacts,belowTable,bondedFaces,fracturedFaces;
};
struct MatterVaporField {
    float* density{},*next{},*sources{};
    physx::PxVec3 origin{0.f,0.f,0.f};
    float cellSize{};
    uint32_t dimension{};
};
// All state is resident on the same CUDA device as PhysX and OpenXR/DX12.
void MatterInitialize(cudaStream_t stream, physx::PxVec4* positions,
    physx::PxVec4* velocities, physx::PxU32* phases,
    float* moisture, float* temperature, float* exposure,
    uint32_t* bondedFaces, uint32_t* brokenFaces, uint32_t count, uint32_t side,
    physx::PxVec3 center, float radius, float invMass, uint32_t wetPhase);
void MatterEvolve(cudaStream_t stream, const physx::PxVec4* positions,
    physx::PxVec4* velocities, physx::PxU32* phases,
    float* moisture, float* nextMoisture, float* temperature, float* exposure,
    uint32_t* bondedFaces, uint32_t* brokenFaces, physx::PxVec4* nextVelocities,
    uint32_t count, uint32_t side, float radius, float waterMass,
    MatterVaporField vapor, uint32_t wetPhase, uint32_t dryPhase,
    const PhysicsLightGpu* lights, uint32_t lightCount,
    const physx::PxTransform* poses, const PhysicsAirflowGpu* airflows,
    uint32_t airflowCount, const physx::PxVec3* angular, float dt, float time,
    uint32_t* phaseChangedDevice, uint32_t* phaseChangedHost,
    uint32_t* velocityChangedDevice, uint32_t* velocityChangedHost);
// Asynchronous full-particle diagnostic, never a CPU simulation proxy.
void MatterProbe(cudaStream_t stream,const physx::PxVec4* positions,
    const float* moisture,const float* temperature,
    const uint32_t* bondedFaces,const uint32_t* brokenFaces,uint32_t count,
    const physx::PxTransform* poses,uint32_t tableIndex,
    physx::PxVec3 tableHalfExtent,float radius,MatterDiagnosticsGpu* output);
void MatterPack(cudaStream_t stream, const physx::PxVec4* positions,
    const float* moisture, uint32_t count, uint32_t base, float radius,
    uint32_t mesh, uint32_t material, bool visible, GpuInstance* instances,
    uint32_t* control);
}
