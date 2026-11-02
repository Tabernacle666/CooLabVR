#include "MatterPbdCuda.h"
#include "AirflowCuda.h"
#include <cuda_runtime.h>
#include <climits>
using namespace physx;
namespace lab {
namespace {
__global__ void Init(PxVec4* positions,PxVec4* velocities,PxU32* phases,
    float* moisture,float* temperature,float* exposure,
    uint32_t* bondedFaces,uint32_t* brokenFaces,uint32_t count,uint32_t side,
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
    bondedFaces[i]=0u;brokenFaces[i]=0u;
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
    float* temperature,float* exposure,const uint32_t* brokenFaces,
    uint32_t count,uint32_t side,float radius,float waterMass,MatterVaporField vapor,
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
    // A mechanically fractured bond opens a face even if the separated
    // particles briefly touch again: the dry shell does not self-heal.
    const uint32_t fractured=brokenFaces[i];
    if(x>0&&!(fractured&1u)&&MatterContact(positions,i,i-1,contact2)){++contacts;neighborWater+=moisture[i-1];}
    if(x+1<side&&i+1<count&&!(fractured&2u)&&MatterContact(positions,i,i+1,contact2)){++contacts;neighborWater+=moisture[i+1];}
    if(z>0&&!(fractured&4u)&&MatterContact(positions,i,i-side,contact2)){++contacts;neighborWater+=moisture[i-side];}
    if(z+1<side&&i+side<count&&!(fractured&8u)&&MatterContact(positions,i,i+side,contact2)){++contacts;neighborWater+=moisture[i+side];}
    if(y>0&&!(fractured&16u)&&MatterContact(positions,i,i-plane,contact2)){++contacts;neighborWater+=moisture[i-plane];}
    if(i+plane<count&&!(fractured&32u)&&MatterContact(positions,i,i+plane,contact2)){++contacts;neighborWater+=moisture[i+plane];}
    const float exposed=fminf(1.f,float(6-contacts)/3.f);
    // Only newly opened material faces produce an evaporation burst.
    const float opening=fmaxf(0.f,exposed-exposure[i]);
    exposure[i]=exposed;
    float w=moisture[i];
    if(contacts)w=fminf(1.f,fmaxf(0.f,w+.18f*dt*(neighborWater/float(contacts)-w)));
    const PxVec4 v=velocities[i];
    const float agitation=sqrtf(v.x*v.x+v.y*v.y+v.z*v.z);
    const float rate=(.035f+.0010f*fmaxf(0.f,t-20.f))
        *(1.f+fminf(4.f,speed*.12f)+fminf(2.f,agitation*.08f))
        *exposed*(1.f+10.f*opening);
    const float loss=fminf(w,rate*dt);
    w-=loss;
    temperature[i]=t-3.f*loss;
    nextMoisture[i]=w;
    const PxU32 updatedPhase=w>.55f?wetPhase:dryPhase;
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

__global__ void CrustForces(const PxVec4* positions,const PxVec4* velocities,
    const float* moisture,uint32_t* bondedFaces,uint32_t* brokenFaces,
    PxVec4* nextVelocities,uint32_t count,uint32_t side,float radius,float dt,
    uint32_t* velocityChanged) {
    const uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i>=count)return;
    const uint32_t x=i%side,z=(i/side)%side,y=i/(side*side),plane=side*side;
    const PxVec4 p=positions[i],v=velocities[i];
    const float dry=fminf(1.f,fmaxf(0.f,(.72f-moisture[i])/.44f));
    uint32_t bonded=bondedFaces[i],broken=brokenFaces[i];
    PxVec3 dv(0.f);
    if(dry>0.f)for(uint32_t face=0;face<6;face++){
        const uint32_t bit=1u<<face;
        if(broken&bit)continue;
        const bool exists=face==0?x>0:face==1?(x+1<side&&i+1<count):
            face==2?z>0:face==3?(z+1<side&&i+side<count):
            face==4?y>0:(i+plane<count);
        if(!exists)continue;
        const uint32_t j=face==0?i-1:face==1?i+1:
            face==2?i-side:face==3?i+side:face==4?i-plane:i+plane;
        const float neighborDry=fminf(1.f,fmaxf(0.f,(.72f-moisture[j])/.44f));
        const float shell=fminf(dry,neighborDry);
        if(shell<=0.f)continue;
        const PxVec4 q=positions[j];
        const PxVec3 separation(q.x-p.x,q.y-p.y,q.z-p.z);
        const float distance=sqrtf(separation.magnitudeSquared());
        const float rest=radius*2.f;
        // A spring can form only while actual PhysX particle centers touch.
        // Broken bonds never reform; no index-driven teleportation or pinning.
        if(!(bonded&bit)){
            if(distance>rest*1.16f)continue;
            bonded|=bit;
        }
        // Tensile fracture is caused by deformation of this bond, including
        // contact impulses from a rigid PhysX tool acting on the particles.
        if(distance>rest*(1.58f-.24f*shell)){
            broken|=bit;
            continue;
        }
        if(distance<1.e-7f)continue;
        const PxVec3 direction=separation/distance;
        const PxVec4 w=velocities[j];
        const float relativeSpeed=(PxVec3(w.x-v.x,w.y-v.y,w.z-v.z)).dot(direction);
        // Explicit damped spring impulse (N*dt/m), only from bonded dry
        // neighbors. PhysX PBD still owns collision, gravity, and integration.
        const float acceleration=3800.f*(distance-rest)+8.f*relativeSpeed;
        dv+=direction*(dt*shell*acceleration);
    }
    bondedFaces[i]=bonded;brokenFaces[i]=broken;
    const float delta2=dv.magnitudeSquared();
    if(delta2>1.e-16f){
        const float length=sqrtf(delta2);
        if(length>.35f)dv*=.35f/length; // stable impulse bound per fixed step
        atomicExch(velocityChanged,1u);
    }
    nextVelocities[i]=PxVec4(v.x+dv.x,v.y+dv.y,v.z+dv.z,v.w);
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
__device__ int OrderedFloat(float value) {
    const int bits=__float_as_int(value);
    return bits<0?(bits^0x7fffffff):bits;
}
__global__ void ResetProbe(MatterDiagnosticsGpu* out) {
    for(int axis=0;axis<3;axis++){out->lower[axis]=INT_MAX;out->upper[axis]=INT_MIN;}
    out->wet=out->dry=out->hot=out->tableContacts=out->belowTable=out->bondedFaces=out->fracturedFaces=0;
}
__global__ void Probe(const PxVec4* positions,const float* moisture,
    const float* temperature,const uint32_t* bondedFaces,const uint32_t* brokenFaces,
    uint32_t count,const PxTransform* poses,
    uint32_t tableIndex,PxVec3 halfExtent,float radius,MatterDiagnosticsGpu* out) {
    constexpr uint32_t BlockSize=256;
    const uint32_t lane=threadIdx.x;
    MatterDiagnosticsGpu local{};
    for(int axis=0;axis<3;axis++){local.lower[axis]=INT_MAX;local.upper[axis]=INT_MIN;}
    const uint32_t stride=gridDim.x*blockDim.x;
    for(uint32_t i=blockIdx.x*blockDim.x+lane;i<count;i+=stride){
        const PxVec4 p=positions[i];
        const int coords[3]={OrderedFloat(p.x),OrderedFloat(p.y),OrderedFloat(p.z)};
        for(int axis=0;axis<3;axis++){
            if(coords[axis]<local.lower[axis])local.lower[axis]=coords[axis];
            if(coords[axis]>local.upper[axis])local.upper[axis]=coords[axis];
        }
        if(moisture[i]>.55f)++local.wet;else ++local.dry;
        if(temperature[i]>30.f)++local.hot;
        local.bondedFaces+=__popc(bondedFaces[i]);
        local.fracturedFaces+=__popc(brokenFaces[i]);
        if(poses&&tableIndex!=0xffffffffu){
            // Contacts are measured against the current oriented GPU box.
            // These counters never exert forces or attach any particle.
            const PxTransform table=poses[tableIndex];
            const PxVec3 q=table.transformInv(PxVec3(p.x,p.y,p.z));
            const float dx=fabsf(q.x)-halfExtent.x;
            const float dy=fabsf(q.y)-halfExtent.y;
            const float dz=fabsf(q.z)-halfExtent.z;
            const float exterior=sqrtf(fmaxf(0.f,dx)*fmaxf(0.f,dx)
                +fmaxf(0.f,dy)*fmaxf(0.f,dy)+fmaxf(0.f,dz)*fmaxf(0.f,dz));
            const float signedDistance=exterior+fminf(0.f,fmaxf(dx,fmaxf(dy,dz)));
            if(fabsf(signedDistance)<=2.5f*radius)++local.tableContacts;
            if(p.y<table.p.y-halfExtent.y-2.f*radius)++local.belowTable;
        }
    }
    __shared__ MatterDiagnosticsGpu partial[BlockSize];
    partial[lane]=local;
    __syncthreads();
    for(uint32_t offset=BlockSize/2;offset;offset>>=1){
        if(lane<offset){
            const auto other=partial[lane+offset];
            for(int axis=0;axis<3;axis++){
                if(other.lower[axis]<partial[lane].lower[axis])partial[lane].lower[axis]=other.lower[axis];
                if(other.upper[axis]>partial[lane].upper[axis])partial[lane].upper[axis]=other.upper[axis];
            }
            partial[lane].wet+=other.wet;
            partial[lane].dry+=other.dry;
            partial[lane].hot+=other.hot;
            partial[lane].tableContacts+=other.tableContacts;
            partial[lane].belowTable+=other.belowTable;
            partial[lane].bondedFaces+=other.bondedFaces;
            partial[lane].fracturedFaces+=other.fracturedFaces;
        }
        __syncthreads();
    }
    if(!lane){
        for(int axis=0;axis<3;axis++){
            atomicMin(&out->lower[axis],partial[0].lower[axis]);
            atomicMax(&out->upper[axis],partial[0].upper[axis]);
        }
        atomicAdd(&out->wet,partial[0].wet);
        atomicAdd(&out->dry,partial[0].dry);
        atomicAdd(&out->hot,partial[0].hot);
        atomicAdd(&out->tableContacts,partial[0].tableContacts);
        atomicAdd(&out->belowTable,partial[0].belowTable);
        atomicAdd(&out->bondedFaces,partial[0].bondedFaces);
        atomicAdd(&out->fracturedFaces,partial[0].fracturedFaces);
    }
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
    float* moisture,float* temperature,float* exposure,
    uint32_t* bondedFaces,uint32_t* brokenFaces,uint32_t n,uint32_t side,
    PxVec3 center,float r,float invMass,PxU32 wetPhase){
    if(n)Init<<<(n+255)/256,256,0,stream>>>(p,v,phases,moisture,temperature,
        exposure,bondedFaces,brokenFaces,n,side,center,r,invMass,wetPhase);
}
void MatterEvolve(cudaStream_t stream,const PxVec4* p,PxVec4* v,
    PxU32* phases,float* moisture,float* nextMoisture,float* temperature,
    float* exposure,uint32_t* bondedFaces,uint32_t* brokenFaces,
    PxVec4* nextVelocities,uint32_t n,uint32_t side,float radius,float waterMass,
    MatterVaporField vapor,PxU32 wet,PxU32 dry,const PhysicsLightGpu* lights,
    uint32_t lightCount,const PxTransform* poses,const PhysicsAirflowGpu* airflows,
    uint32_t airflowCount,const PxVec3* angular,float dt,float time,
    uint32_t* phaseChangedDevice,uint32_t* phaseChangedHost,
    uint32_t* velocityChangedDevice,uint32_t* velocityChangedHost){
    if(!n)return;
    cudaMemsetAsync(phaseChangedDevice,0,sizeof(uint32_t),stream);
    cudaMemsetAsync(velocityChangedDevice,0,sizeof(uint32_t),stream);
    cudaMemsetAsync(vapor.sources,0,vapor.dimension*vapor.dimension*vapor.dimension*sizeof(float),stream);
    Environment<<<(n+255)/256,256,0,stream>>>(p,v,phases,moisture,nextMoisture,
        temperature,exposure,brokenFaces,n,side,radius,waterMass,vapor,wet,dry,lights,
        lightCount,poses,airflows,airflowCount,angular,dt,time,phaseChangedDevice);
    // Apply mechanical cohesion only where the local field has formed a dry
    // shell. The saved rupture mask changes the next humidity/exposure step.
    CrustForces<<<(n+255)/256,256,0,stream>>>(p,v,nextMoisture,
        bondedFaces,brokenFaces,nextVelocities,n,side,radius,dt,velocityChangedDevice);
    cudaMemcpyAsync(v,nextVelocities,n*sizeof(PxVec4),
        cudaMemcpyDeviceToDevice,stream);
    cudaMemcpyAsync(velocityChangedHost,velocityChangedDevice,
        sizeof(uint32_t),cudaMemcpyDeviceToHost,stream);
    const uint32_t cells=vapor.dimension*vapor.dimension*vapor.dimension;
    TransportVapor<<<(cells+255)/256,256,0,stream>>>(vapor,airflows,
        airflowCount,poses,angular,dt,time);
    cudaMemcpyAsync(moisture,nextMoisture,n*sizeof(float),cudaMemcpyDeviceToDevice,stream);
    cudaMemcpyAsync(phaseChangedHost,phaseChangedDevice,sizeof(uint32_t),cudaMemcpyDeviceToHost,stream);
}
void MatterProbe(cudaStream_t stream,const PxVec4* positions,
    const float* moisture,const float* temperature,
    const uint32_t* bondedFaces,const uint32_t* brokenFaces,uint32_t n,
    const PxTransform* poses,uint32_t tableIndex,PxVec3 halfExtent,float radius,
    MatterDiagnosticsGpu* out) {
    ResetProbe<<<1,1,0,stream>>>(out);
    if(n)Probe<<<256,256,0,stream>>>(positions,moisture,temperature,
        bondedFaces,brokenFaces,n,
        poses,tableIndex,halfExtent,radius,out);
}
void MatterPack(cudaStream_t stream,const PxVec4* p,const float* moisture,
    uint32_t n,uint32_t base,float radius,uint32_t mesh,uint32_t material,
    bool visible,GpuInstance* instances,uint32_t* control) {
    if(n)Pack<<<(n+255)/256,256,0,stream>>>(p,moisture,n,base,radius,mesh,
        material,visible,instances,control);
}
}
