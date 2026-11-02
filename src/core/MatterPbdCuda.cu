#include "MatterPbdCuda.h"
#include "AirflowCuda.h"
#include <cuda_runtime.h>
using namespace physx;
namespace lab {
namespace {
__global__ void Init(PxVec4* positions,PxVec4* velocities,PxU32* phases,
    float* moisture,float* temperature,float* exposure,uint32_t count,uint32_t side,
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
    const uint32_t missing=(x==0)+(x+1==side)+(z==0)+(z+1==side)
        +(y==0)+(i+side*side>=count);
    exposure[i]=fminf(1.f,float(missing)/3.f);
}
__device__ bool MatterContact(const PxVec4* positions,uint32_t a,uint32_t b,float r2) {
    const PxVec4 p=positions[a],q=positions[b];
    const float dx=p.x-q.x,dy=p.y-q.y,dz=p.z-q.z;
    return dx*dx+dy*dy+dz*dz<=r2;
}
__device__ uint32_t VaporIndex(uint32_t x,uint32_t y,uint32_t z,uint32_t n) {
    return (z*n+y)*n+x;
}
__device__ float VaporAt(const float* values,MatterVaporField grid,PxVec3 p) {
    const float x=(p.x-grid.origin.x)/grid.cellSize-.5f;
    const float y=(p.y-grid.origin.y)/grid.cellSize-.5f;
    const float z=(p.z-grid.origin.z)/grid.cellSize-.5f;
    const int ix=int(floorf(x)),iy=int(floorf(y)),iz=int(floorf(z));
    const int n=int(grid.dimension);
    if(ix<0||iy<0||iz<0||ix+1>=n||iy+1>=n||iz+1>=n)return 0.f;
    const float fx=x-float(ix),fy=y-float(iy),fz=z-float(iz);
    const uint32_t a=VaporIndex(uint32_t(ix),uint32_t(iy),uint32_t(iz),grid.dimension);
    const uint32_t dx=1,dy=grid.dimension,dz=grid.dimension*grid.dimension;
    const float c00=values[a]*(1-fx)+values[a+dx]*fx;
    const float c10=values[a+dy]*(1-fx)+values[a+dy+dx]*fx;
    const float c01=values[a+dz]*(1-fx)+values[a+dz+dx]*fx;
    const float c11=values[a+dz+dy]*(1-fx)+values[a+dz+dy+dx]*fx;
    return (c00*(1-fy)+c10*fy)*(1-fz)+(c01*(1-fy)+c11*fy)*fz;
}
__global__ void Environment(const PxVec4* positions,const PxVec4* velocities,
    PxU32* phases,const float* moisture,float* nextMoisture,
    float* temperature,float* exposure,uint32_t count,uint32_t side,
    float radius,float waterMass,MatterVaporField vapor,
    PxU32 wetPhase,PxU32 dryPhase,const PhysicsLightGpu* lights,uint32_t lightCount,
    const PxTransform* poses,const PhysicsAirflowGpu* airflows,uint32_t airflowCount,
    const PxVec3* angular,float dt,float time,uint32_t* phaseChanged) {
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
    // The initial six-neighbor material graph is evaluated against CURRENT
    // PhysX positions. A missing contact is an exterior face or a physical
    // separation; a closed core has no direct air exposure.
    const uint32_t x=i%side,z=(i/side)%side,y=i/(side*side);
    const uint32_t plane=side*side;
    const float contact2=(radius*2.8f)*(radius*2.8f);
    uint32_t contacts=0;float neighborWater=0.f;
    if(x>0&&MatterContact(positions,i,i-1,contact2)){++contacts;neighborWater+=moisture[i-1];}
    if(x+1<side&&i+1<count&&MatterContact(positions,i,i+1,contact2)){++contacts;neighborWater+=moisture[i+1];}
    if(z>0&&MatterContact(positions,i,i-side,contact2)){++contacts;neighborWater+=moisture[i-side];}
    if(z+1<side&&i+side<count&&MatterContact(positions,i,i+side,contact2)){++contacts;neighborWater+=moisture[i+side];}
    if(y>0&&MatterContact(positions,i,i-plane,contact2)){++contacts;neighborWater+=moisture[i-plane];}
    if(i+plane<count&&MatterContact(positions,i,i+plane,contact2)){++contacts;neighborWater+=moisture[i+plane];}
    const float exposed=fminf(1.f,float(6-contacts)/3.f);
    // Only newly opened material faces produce an evaporation burst.
    const float opening=fmaxf(0.f,exposed-exposure[i]);
    exposure[i]=exposed;
    float w=moisture[i];
    if(contacts)w=fminf(1.f,fmaxf(0.f,w+.18f*dt*(neighborWater/float(contacts)-w)));
    const PxVec4 v=velocities[i];
    const float agitation=sqrtf(v.x*v.x+v.y*v.y+v.z*v.z);
    const float rate=(.008f+.0008f*fmaxf(0.f,t-20.f))
        *(1.f+fminf(4.f,speed*.12f)+fminf(2.f,agitation*.08f))
        *exposed*(1.f+10.f*opening);
    const float loss=fminf(w,rate*dt);
    w-=loss;
    temperature[i]=t-3.f*loss;
    nextMoisture[i]=w;
    const PxU32 updatedPhase=w>.28f?wetPhase:dryPhase;
    if(phases[i]!=updatedPhase){
        phases[i]=updatedPhase;
        atomicExch(phaseChanged,1u);
    } // GPU PBD phases are dirtied by actual material transitions only
    // Every water decrement creates physical vapor mass in the CUDA grid.
    if(loss>0.f){
        const int gx=int(floorf((p.x-vapor.origin.x)/vapor.cellSize));
        const int gy=int(floorf((p.y-vapor.origin.y)/vapor.cellSize));
        const int gz=int(floorf((p.z-vapor.origin.z)/vapor.cellSize));
        const int n=int(vapor.dimension);
        if(gx>=0&&gy>=0&&gz>=0&&gx<n&&gy<n&&gz<n)
            atomicAdd(&vapor.sources[VaporIndex(uint32_t(gx),uint32_t(gy),uint32_t(gz),vapor.dimension)],loss*waterMass);
    }
}
__global__ void TransportVapor(MatterVaporField vapor,const PhysicsAirflowGpu* airflows,
    uint32_t airflowCount,const PxTransform* poses,const PxVec3* angular,float dt,float time) {
    const uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;
    const uint32_t n=vapor.dimension,volume=n*n*n;
    if(i>=volume)return;
    const uint32_t x=i%n,y=(i/n)%n,z=i/(n*n);
    const PxVec3 p=vapor.origin+PxVec3((x+.5f)*vapor.cellSize,
        (y+.5f)*vapor.cellSize,(z+.5f)*vapor.cellSize);
    // Semi-Lagrangian transport by the same real CUDA rotor field as solids
    // and insects, plus buoyant convection and weak molecular mixing.
    const PxVec3 flow=(airflowCount&&poses&&angular)?
        AirVelocity(airflows,airflowCount,poses,angular,p,time):PxVec3(0.f);
    const PxVec3 back=p-(flow+PxVec3(0.f,.08f,0.f))*dt;
    float concentration=VaporAt(vapor.density,vapor,back);
    const float old=vapor.density[i];
    const uint32_t strideY=n,strideZ=n*n;
    const float avg=(vapor.density[x?i-1:i]+vapor.density[x+1<n?i+1:i]
        +vapor.density[y?i-strideY:i]+vapor.density[y+1<n?i+strideY:i]
        +vapor.density[z?i-strideZ:i]+vapor.density[z+1<n?i+strideZ:i])*(1.f/6.f);
    concentration+=fminf(.2f,dt*.6f)*(avg-old);
    const float volumeM3=vapor.cellSize*vapor.cellSize*vapor.cellSize;
    concentration+=vapor.sources[i]/volumeM3;
    vapor.next[i]=fmaxf(0.f,concentration)*expf(-.08f*dt);
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
    float* moisture,float* temperature,float* exposure,uint32_t n,uint32_t side,
    PxVec3 center,float r,float invMass,PxU32 wetPhase){
    if(n)Init<<<(n+255)/256,256,0,stream>>>(p,v,phases,moisture,temperature,
        exposure,n,side,center,r,invMass,wetPhase);
}
void MatterEvolve(cudaStream_t stream,const PxVec4* p,const PxVec4* v,
    PxU32* phases,float* moisture,float* nextMoisture,float* temperature,
    float* exposure,uint32_t n,uint32_t side,float radius,float waterMass,
    MatterVaporField vapor,PxU32 wet,PxU32 dry,const PhysicsLightGpu* lights,
    uint32_t lightCount,const PxTransform* poses,const PhysicsAirflowGpu* airflows,
    uint32_t airflowCount,const PxVec3* angular,float dt,float time,
    uint32_t* phaseChangedDevice,uint32_t* phaseChangedHost){
    if(!n)return;
    cudaMemsetAsync(phaseChangedDevice,0,sizeof(uint32_t),stream);
    cudaMemsetAsync(vapor.sources,0,vapor.dimension*vapor.dimension*vapor.dimension*sizeof(float),stream);
    Environment<<<(n+255)/256,256,0,stream>>>(p,v,phases,moisture,nextMoisture,
        temperature,exposure,n,side,radius,waterMass,vapor,wet,dry,lights,
        lightCount,poses,airflows,airflowCount,angular,dt,time,phaseChangedDevice);
    const uint32_t cells=vapor.dimension*vapor.dimension*vapor.dimension;
    TransportVapor<<<(cells+255)/256,256,0,stream>>>(vapor,airflows,
        airflowCount,poses,angular,dt,time);
    cudaMemcpyAsync(moisture,nextMoisture,n*sizeof(float),cudaMemcpyDeviceToDevice,stream);
    cudaMemcpyAsync(phaseChangedHost,phaseChangedDevice,sizeof(uint32_t),cudaMemcpyDeviceToHost,stream);
}
void MatterPack(cudaStream_t stream,const PxVec4* p,const float* moisture,
    uint32_t n,uint32_t base,float radius,uint32_t mesh,uint32_t material,
    bool visible,GpuInstance* instances,uint32_t* control) {
    if(n)Pack<<<(n+255)/256,256,0,stream>>>(p,moisture,n,base,radius,mesh,
        material,visible,instances,control);
}
}
