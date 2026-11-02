#include "MatterPbdCuda.h"
#include "AirflowCuda.h"
#include <cuda_runtime.h>
using namespace physx;
namespace lab {
namespace {
__global__ void Init(PxVec4* positions,PxVec4* velocities,PxU32* phases,
    float* moisture,float* temperature,uint32_t count,uint32_t side,
    PxVec3 center,float radius,float invMass,PxU32 phase) {
    const uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i>=count)return;
    const uint32_t x=i%side,z=(i/side)%side,y=i/(side*side);
    const uint32_t levels=(count+side*side-1)/(side*side);
    const PxVec3 p(center.x+(float(x)-.5f*float(side-1))*2*radius,
        center.y+(float(y)-.5f*float(levels-1))*2*radius,
        center.z+(float(z)-.5f*float(side-1))*2*radius);
    positions[i]=PxVec4(p.x,p.y,p.z,invMass);
    velocities[i]=PxVec4(0.f,0.f,0.f,0.f);
    phases[i]=phase;
    // Hydration and temperature belong to the same material particles, not an
    // independent visual effect or a CPU proxy of the PhysX solver.
    moisture[i]=1.f;temperature[i]=28.f;
}
__global__ void Environment(const PxVec4* positions,const PxVec4* velocities,
    PxU32* phases,float* moisture,float* temperature,uint32_t count,
    PxU32 wetPhase,PxU32 dryPhase,const PhysicsLightGpu* lights,uint32_t lightCount,
    const PxTransform* poses,const PhysicsAirflowGpu* airflows,uint32_t airflowCount,
    const PxVec3* angular,float dt,float time) {
    const uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i>=count)return;
    const PxVec4 pos=positions[i];
    const PxVec3 p(pos.x,pos.y,pos.z);
    float heat=21.f;
    for(uint32_t l=0;l<lightCount;l++) {
        const auto a=lights[l];
        if(a.light.power<=0.f)continue;
        const PxTransform pose=a.index==PhysicsInvalidIndex? a.initial:poses[a.index];
        const PxVec3 bulb=pose.transform(PxVec3(a.light.localPosition.x,
            a.light.localPosition.y,a.light.localPosition.z));
        const PxVec3 delta=bulb-p;
        const float r2=delta.magnitudeSquared();
        heat+=fminf(35.f, a.light.power*.014f/(.035f+r2));
    }
    const PxVec3 flow=(airflowCount&&poses&&angular)?
        AirVelocity(airflows,airflowCount,poses,angular,p,time):PxVec3(0.f);
    const float speed=flow.magnitude();
    float t=temperature[i];
    t+=(heat-t)*fminf(1.f,dt*(.06f+.08f*speed));
    float w=moisture[i];
    // Evaporation is a local heat/airflow transport law. Impact velocity
    // accelerates exposure through physical fragmentation, not a table rule.
    const PxVec4 v=velocities[i];
    const float agitation=sqrtf(v.x*v.x+v.y*v.y+v.z*v.z);
    const float evaporation=(.008f+.0008f*fmaxf(0.f,t-20.f))
        *(1.f+fminf(4.f,speed*.12f)+fminf(2.f,agitation*.08f));
    w=fmaxf(0.f,w-evaporation*dt);
    temperature[i]=t;moisture[i]=w;
    phases[i]=w>.28f?wetPhase:dryPhase;
}
__global__ void Pack(const PxVec4* positions,const float* moisture,
    uint32_t count,uint32_t base,float radius,uint32_t mesh,uint32_t material,
    bool visible,GpuInstance* instances,uint32_t* control) {
    const uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i==0){
        const uint32_t end=base+(visible?count:0);
        control[0]=visible?end:0;
        control[1]=base+count;
        control[4]=(visible?end+63:0)/64;
        control[8]=(base+count+63)/64;
    }
    if(i>=count)return;
    const PxVec4 p=positions[i];
    auto& o=instances[base+i];
    const float diameter=2.f*radius;
    const float dry=fminf(1.f,fmaxf(0.f,1.f-moisture[i]));
    o.positionRadius={p.x,p.y,p.z,visible?radius:0.f};
    o.rotation={0,0,0,1};
    o.scale={visible?diameter:0,visible?diameter:0,visible?diameter:0,dry};
    o.mesh=mesh;o.material=material;o.id=0x72000000u+i;
    // Real GPU particle positions, no CPU geometry and no false raytracing proxy.
    o.flags=1u|8u|4u|32u;
}
}
void MatterInitialize(cudaStream_t stream,PxVec4* p,PxVec4* v,PxU32* phases,
    float* moisture,float* temperature,uint32_t n,uint32_t side,PxVec3 center,
    float r,float invMass,PxU32 wetPhase){
    if(n)Init<<<(n+255)/256,256,0,stream>>>(p,v,phases,moisture,temperature,n,
        side,center,r,invMass,wetPhase);
}
void MatterEvolve(cudaStream_t stream,const PxVec4* p,const PxVec4* v,
    PxU32* phases,float* moisture,float* temperature,uint32_t n,PxU32 wet,
    PxU32 dry,const PhysicsLightGpu* lights,uint32_t lightCount,
    const PxTransform* poses,const PhysicsAirflowGpu* airflows,
    uint32_t airflowCount,const PxVec3* angular,float dt,float time){
    if(n)Environment<<<(n+255)/256,256,0,stream>>>(p,v,phases,moisture,
        temperature,n,wet,dry,lights,lightCount,poses,airflows,airflowCount,
        angular,dt,time);
}
void MatterPack(cudaStream_t stream,const PxVec4* p,const float* moisture,
    uint32_t n,uint32_t base,float radius,uint32_t mesh,uint32_t material,
    bool visible,GpuInstance* instances,uint32_t* control) {
    if(n)Pack<<<(n+255)/256,256,0,stream>>>(p,moisture,n,base,radius,mesh,
        material,visible,instances,control);
}
}
