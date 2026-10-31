#include "HomePhysics.h"
#include "LaboVRVisualService.h"
#include "LaboVRTerminal.h"
#include "ClientAssets.h"
#include "SessionLog.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
namespace lab {
namespace {
enum HomePhysicsMesh:uint32_t {Link=3,Socket,Glass,Thorax,Head,Abdomen,Eye,WingLeft,VeinsLeft,WingRight,VeinsRight,Leg,Foot,Antennae,Proxy,MeshEnd};
constexpr uint32_t RoomLayer=1,ChainLayer=2,InsectLayer=4,HandLayer=8;
void Require(LabU32 result,const char* operation){if(!result)Fail(operation);}
LabVec3V1 V(XMFLOAT3 v){return {v.x,v.y,v.z};}
XMFLOAT3 V(LabVec3V1 v){return {v.x,v.y,v.z};}
LabQuatV1 Rotation(float x,float y,float z){XMFLOAT4 q;XMStoreFloat4(&q,XMQuaternionRotationRollPitchYaw(x,y,z));return {q.x,q.y,q.z,q.w};}
LabPoseV1 PoseAt(XMFLOAT3 p,LabQuatV1 q={0,0,0,1}){return {V(p),q};}
XMFLOAT3 Rotated(XMFLOAT3 v,LabQuatV1 q){XMFLOAT3 out;XMStoreFloat3(&out,XMVector3Rotate(XMLoadFloat3(&v),XMVectorSet(q.x,q.y,q.z,q.w)));return out;}
LabQuatV1 Relative(LabQuatV1 parent,LabQuatV1 child,LabQuatV1 frame){auto a=XMVectorSet(parent.x,parent.y,parent.z,parent.w),b=XMVectorSet(child.x,child.y,child.z,child.w),f=XMVectorSet(frame.x,frame.y,frame.z,frame.w);XMFLOAT4 q;XMStoreFloat4(&q,XMQuaternionMultiply(XMQuaternionMultiply(f,a),XMQuaternionInverse(b)));return {q.x,q.y,q.z,q.w};}
LabPhysicsBodyDescV1 Description(uint32_t kind,uint32_t shape,XMFLOAT3 position,XMFLOAT3 dimensions,float mass,uint32_t layer){
    LabPhysicsBodyDescV1 d{};d.structSize=sizeof(d);d.kind=kind;d.shape=shape;d.layer=layer;d.collisionMask=RoomLayer|ChainLayer|InsectLayer|HandLayer;d.pose=PoseAt(position);d.shapePose=PoseAt({0,0,0});d.dimensions=V(dimensions);d.mass=mass;d.staticFriction=.6f;d.dynamicFriction=.4f;d.restitution=.12f;d.linearDamping=.08f;d.angularDamping=.18f;d.contactOffset=.002f;d.restOffset=0;d.maxAngularVelocity=220;return d;
}
LabPhysicsD6DescV1 Connection(LabPhysicsBodyV1 a,LabPhysicsBodyV1 b,LabPoseV1 pa,LabPoseV1 pb,bool flexible){
    LabPhysicsD6DescV1 d{};d.structSize=sizeof(d);d.bodyA=a;d.bodyB=b;d.frameA=pa;d.frameB=pb;
    if(flexible){for(uint32_t i=3;i<6;i++)d.motion[i]=LAB_PHYSICS_LIMITED;d.twistLower=-.75f;d.twistUpper=.75f;d.swingY=.70f;d.swingZ=.70f;}
    return d;
}
LabPhysicsCommandV1 Command(uint32_t kind,LabPhysicsBodyV1 body,XMFLOAT3 value){LabPhysicsCommandV1 c{};c.structSize=sizeof(c);c.kind=kind;c.body=body;c.value=V(value);c.target=PoseAt({0,0,0});return c;}
}
LabPhysicsBodyV1 HomePhysics::Body(const LabPhysicsBodyDescV1& d){LabPhysicsBodyV1 body{};Require(physics_->CreateBody(physics_->serviceContext,scene_,&d,&body),"Home physics_v1: body creation rejected");std::string id="body-"+std::to_string(entities_.size());entities_.push_back({id,id,body,d.pose,buildingGroup_});return body;}
LabPhysicsJointV1 HomePhysics::Joint(const LabPhysicsD6DescV1& d){LabPhysicsJointV1 joint{};Require(physics_->CreateD6(physics_->serviceContext,scene_,&d,&joint),"Home physics_v1: D6 creation rejected");auto id=[&](LabPhysicsBodyV1 h){for(const auto& e:entities_)if(e.body==h)return e.id;return std::string("world-anchor");};connections_.push_back({id(d.bodyA)+"--"+id(d.bodyB),joint,d.frameA,d.frameB,d.bodyA,d.bodyB});return joint;}
void HomePhysics::Visual(LabPhysicsBodyV1 body,uint32_t mesh,Material material,XMFLOAT3 scale,LabPoseV1 local,uint32_t flags){LabPhysicsVisualV1 v{};v.structSize=sizeof(v);v.body=body;v.mesh=mesh;v.material=uint32_t(material);v.id=0x70000000u+uint32_t(visuals_.size());v.flags=flags;v.localPose=local;v.scale=V(scale);v.boundingRadius=Length(scale);visuals_.push_back(v);}
void HomePhysics::Load(const LabHostApiV1& host,SceneData& assets){
    if(scene_)Fail("Home physical scene already loaded");
    if(host.abiVersion!=1||host.structSize<sizeof(host)||!host.QueryService)Fail("Home requires the public host API");
    physics_=static_cast<const LabPhysicsServiceV1*>(host.QueryService(host.hostContext,LABOVR_SERVICE_PHYSICS_V1,1));
    storage_=static_cast<const LabStorageServiceV1*>(host.QueryService(host.hostContext,LABOVR_SERVICE_STORAGE_V1,1));
    input_=static_cast<const LabInputServiceV1*>(host.QueryService(host.hostContext,LABOVR_SERVICE_INPUT_V1,1));
    audio_=static_cast<const LabAudioServiceV1*>(host.QueryService(host.hostContext,LABOVR_SERVICE_AUDIO_V1,1));
    gpu_=static_cast<const LabGpuServiceV1*>(host.QueryService(host.hostContext,LABOVR_SERVICE_GPU_V1,1));
    if(!storage_||storage_->structSize<sizeof(*storage_)||!physics_||physics_->version!=1||physics_->structSize<sizeof(*physics_)||!physics_->CreatePopulation||!physics_->PollPopulation||!physics_->SetPopulationEffects||!physics_->SetPopulationHands||!physics_->SetBodyCollisionEnabled||!input_||input_->structSize<sizeof(*input_)||!input_->GetPhysicalSources||!input_->SetBooleanSources||!audio_||audio_->structSize<sizeof(*audio_)||!audio_->SetAcousticBoxes||!gpu_||gpu_->structSize<sizeof(*gpu_)||!gpu_->SetFogSettings||!gpu_->SetFogInput||!gpu_->SetPopulationOpticalSettings||!gpu_->RequestCapture||!gpu_->GetCaptureStatus||!gpu_->SetAntialiasing||!gpu_->SetFogTransport||!gpu_->SetSurfaceSettings||!gpu_->SetMultisampling||!physics_->SetAirflows||!physics_->SetPopulationSpace)Fail("Home requires SDK physics_v1/input_v1/audio_v1/gpu_v1");
    // Bound GPU PhysX synchronization to at most two fixed steps per rendered
    // frame. An 8 x 240 Hz catch-up loop can amplify frame overruns: each
    // substep blocks on fetchResults(), then the next frame tries to catch up.
    // 120 Hz preserves a fixed integration step; overdue time is discarded.
    LabPhysicsSceneDescV1 scene{sizeof(scene),128,{0,-9.81f,0},1.f/120.f,2,0};Require(physics_->CreateScene(physics_->serviceContext,&scene,&scene_),"Home physics_v1: scene creation failed");
    Require(input_->ResolveAction(input_->serviceContext,"tracking.hand_pose",&handPose_),"Home input_v1: existing hand pose unavailable");
    Require(input_->ResolveAction(input_->serviceContext,"interaction.physical",&physicalAction_),"Home input_v1: physical hand action unavailable");
    Require(input_->ResolveAction(input_->serviceContext,"interaction.grab",&grabAction_),"Home input_v1: grab action unavailable");
    sweepTracked_={};sweepVelocity_={};sweeps_={sizeof(sweeps_)};populationCount_=1;if(nextFlyAudioId_>=0x01000000u||nextFanAudioId_>0x00fffffcu)Fail("Home audio identity space exhausted");
    flyAudioIds_={nextFlyAudioId_++};fanAudioBase_=nextFanAudioId_;nextFanAudioId_+=3;populationInput_={sizeof(LabPopulationInputV1),1};lampPower_=26;Build(assets);LabPhysicsBodyV1 probes[]{bulb_,socket_,pullSlider_,pullHandle_,fanRotor_};Require(physics_->SetProbes(physics_->serviceContext,scene_,probes,uint32_t(std::size(probes))),"Home physics_v1: behavior/audio probes rejected");
    provider_.structSize=sizeof(provider_);Require(physics_->GetVisualProvider(physics_->serviceContext,scene_,&provider_),"Home physics_v1: GPU visual provider unavailable");Require(gpu_->SetPublicationProvider(gpu_->serviceContext,&provider_),"Home gpu_v1: physical visual provider rejected");
    lastUpdateSeconds_=0;trackingRevision_=sourceFrame_=0;stateSeconds_=0;population_={};population_.structSize=sizeof(population_);population_.targetId=Invalid;states_={};visible_=true;pullArmed_=true;hands_={};grips_={};handTracked_={};handColliding_={};handBlocked_={};frozen_=false;selection_=0;simulationSeconds_=0;fanActualRpm_=0;
    panelPose_={{0,1.875f,3.96f},{0,0,0,1}};panelTheme_=panelFace_=0;panelSelected_=false;
    SyncTouchSources();BuildSelections();if(!ReadProfile(LAB_PROFILE_USER_V1,true)){auto userStatus=status_;if(ReadProfile(LAB_PROFILE_SYSTEM_V1,true)&&userStatus!="READY")status_="USER: "+userStatus+" / SYSTEM LOADED";}PublishRendering();PublishAcoustics();
}
void HomePhysics::Unload(){
    if(!scene_)return;auto opticalOff=optical_;opticalOff.enabled=0;gpu_->SetPopulationOpticalSettings(gpu_->serviceContext,&opticalOff);audio_->SetAcousticBoxes(audio_->serviceContext,nullptr,0);auto off=fog_;off.enabled=0;Require(gpu_->SetFogSettings(gpu_->serviceContext,&off),"Home gpu_v1: volume detach rejected");Require(gpu_->SetPublicationProvider(gpu_->serviceContext,nullptr),"Home gpu_v1: detach failed");
    LabAudioEmitterBatchV1 silence{1,sizeof(silence),0,nullptr,0,0};Require(audio_->PublishEmitters(audio_->serviceContext,&silence),"Home audio_v1: emitter detach failed");Require(physics_->DestroyScene(physics_->serviceContext,scene_),"Home physics_v1: scene destruction failed");
    entities_.clear();connections_.clear();selections_.clear();scene_=0;hands_={};grips_={};handTracked_={};handColliding_={};provider_={};visuals_.clear();physics_=nullptr;input_=nullptr;audio_=nullptr;gpu_=nullptr;
}
void HomePhysics::SetVisible(bool visible){
    visible_=visible;PublishAcoustics();PublishOptical();
    auto volume=fog_;volume.enabled=fog_.enabled&&visible_;Require(gpu_->SetFogSettings(gpu_->serviceContext,&volume),"Home gpu_v1: volume visibility rejected");if(!scene_)return;
    Require(physics_->SetVisible(physics_->serviceContext,scene_,visible?1u:0u),"Home physics_v1: visibility update failed");
    if(!visible)for(uint32_t hand=0;hand<2;hand++){
        ReleaseHand(hand,false);handBlocked_[hand]=true;
        if(hands_[hand]&&handColliding_[hand]){Require(physics_->SetBodyCollisionEnabled(physics_->serviceContext,scene_,hands_[hand],0),"Home physics_v1: hidden hand collision disable rejected");handColliding_[hand]=false;}
    }
}
void HomePhysics::SetLampEnabled(bool value){
    if(!scene_)return;lampPower_=value?26.f:0.f;lampLight_.power=lampPower_;
    for(auto& v:visuals_)if(v.body==bulb_)v.material=uint32_t(lampPower_>0?Material::Bulb:Material::Charcoal);
    Require(physics_->SetVisuals(physics_->serviceContext,scene_,visuals_.data(),uint32_t(visuals_.size()),&lampLight_,1),"Home physics_v1: lamp state update rejected");
    LogEvent(sourceFrame_,"home.lamp","enabled=%u power=%.1f material=%u body=%llu",unsigned(value),lampPower_,uint32_t(value?Material::Bulb:Material::Charcoal),static_cast<unsigned long long>(bulb_));
}
void HomePhysics::Build(SceneData& assets){
    SceneData meshAssets;meshAssets.meshes=LoadGLTF(AssetPath(L"assets/home_physics.gltf"));if(meshAssets.meshes.ranges.size()!=MeshEnd-uint32_t(Mesh::Count))Fail("Home physical mesh library mismatch");AppendClientScene(assets,meshAssets);
    auto& m=assets.materials;
    m[uint32_t(Material::Steel)]={{.22f,.27f,.33f,.22f},{0,0,0,.88f}};
    m[uint32_t(Material::Chain)]={{.18f,.21f,.24f,.18f},{0,0,0,.94f}};
    m[uint32_t(Material::Bulb)]={{.82f,.67f,.40f,.22f},{3.4f,1.58f,.42f,0}};
    m[uint32_t(Material::Filament)]={{.5f,.17f,.025f,.14f},{7.f,2.1f,.30f,.2f}};
    m[uint32_t(Material::Fly)]={{.045f,.070f,.046f,.28f},{0,0,0,.65f}};
    m[uint32_t(Material::Gun)]={{.16f,.009f,.013f,.20f},{0,0,0,.18f}};
    m[uint32_t(Material::Glue)]={{.20f,.26f,.32f,.25f},{0,0,0,.60f}};
    m[uint32_t(Material::Charcoal)]={{.008f,.012f,.010f,.55f},{0,0,0,.15f}};
    m[uint32_t(Material::Glue)].doubleSided=1;
    // Room colliders are exactly the visible room boxes, not a second hidden
    // boundary. Their dimensions and material response use the public ABI.
    const char* roomNames[]{"Floor","Ceiling","Wall -Z","Wall -X","Wall +X"};
    const char* roomIds[]{"room-floor","room-ceiling","room-zminus","room-xminus","room-xplus"};
    const char* furnitureIds[]{"table-top","table-leg-1","table-leg-2","table-leg-3","table-leg-4"};
    const char* furnitureNames[]{"Table top","Table leg 1","Table leg 2","Table leg 3","Table leg 4"};
    uint32_t ordinal=0;
    for(const auto& object:assets.objects){buildingGroup_=ordinal<5?0:1;
        auto d=Description(LAB_PHYSICS_STATIC,LAB_PHYSICS_BOX,object.current.p,Scale(object.scale,.5f),0,RoomLayer);d.collisionGroup=ordinal<5?0x400u:0x300u;auto body=Body(d);
        entities_.back().id=ordinal<5?roomIds[ordinal]:furnitureIds[ordinal-5];entities_.back().name=ordinal<5?roomNames[ordinal]:furnitureNames[ordinal-5];entities_.back().acousticHalfExtent=d.dimensions;
        Visual(body,object.mesh,Material(object.material),object.scale,PoseAt({0,0,0}),object.flags);++ordinal;
    }
    assets.objects.clear();buildingGroup_=3;
    const XMFLOAT3 anchor{-.85f,3.70f,1.15f};
    auto support=Body(Description(LAB_PHYSICS_STATIC,LAB_PHYSICS_BOX,anchor,{.095f,.050f,.095f},0,ChainLayer));
    entities_.back().id="lamp-ceiling-anchor";entities_.back().name="Lamp ceiling anchor";
    Visual(support,Socket,Material::Steel,{.22f,.10f,.22f},PoseAt({0,0,0}),0);
    // The black load-bearing cable and the metal switch chain have separate
    // actors and constraints. Every visible segment is driven by PhysX poses.
    constexpr uint32_t cableSegments=14;constexpr float cablePitch=.10f;
    LabPhysicsBodyV1 previous{};
    for(uint32_t i=0;i<cableSegments;i++){
        auto d=Description(LAB_PHYSICS_DYNAMIC,LAB_PHYSICS_CAPSULE,{anchor.x,anchor.y-cablePitch*(float(i)+.5f),anchor.z},{.008f,.042f,0},.009f,ChainLayer);
        d.shapePose.orientation=Rotation(0,0,XM_PIDIV2);d.collisionGroup=0x100;d.contactOffset=.001f;d.angularDamping=.35f;
        auto segment=Body(d);entities_.back().id="lamp-cable-"+std::to_string(i);entities_.back().name="Black cable "+std::to_string(i+1);Visual(segment,uint32_t(Mesh::Cylinder),Material::Charcoal,{.016f,cablePitch,.016f});
        auto joint=Connection(i?previous:support,segment,PoseAt({0,i?-cablePitch*.5f:0,0}),PoseAt({0,cablePitch*.5f,0}),true);
        joint.twistLower=-.4f;joint.twistUpper=.4f;joint.swingY=joint.swingZ=.45f;
        joint.drive[LAB_PHYSICS_DRIVE_SLERP]={.0012f,.00008f,.003f,0};Joint(joint);previous=segment;
    }
    const float hubY=anchor.y-cableSegments*cablePitch-.060f;
    auto socketDesc=Description(LAB_PHYSICS_DYNAMIC,LAB_PHYSICS_CAPSULE,{anchor.x,hubY,anchor.z},{.038f,.025f,0},.11f,ChainLayer);socketDesc.shapePose.orientation=Rotation(0,0,XM_PIDIV2);socket_=Body(socketDesc);entities_.back().id="lamp-socket";entities_.back().name="Hub / socket";
    Visual(socket_,Socket,Material::Steel,{.095f,.12f,.095f});
    Joint(Connection(previous,socket_,PoseAt({0,-cablePitch*.5f,0}),PoseAt({0,.06f,0}),true));
    auto bulbDesc=Description(LAB_PHYSICS_DYNAMIC,LAB_PHYSICS_SPHERE,{anchor.x,hubY-.110f,anchor.z},{.065f,0,0},.045f,ChainLayer);bulbDesc.shapePose.position={0,-.02f,0};bulb_=Body(bulbDesc);entities_.back().id="lamp-bulb";entities_.back().name="Bulb";
    Visual(bulb_,Glass,Material::Bulb,{.15f,.15f,.15f},PoseAt({0,0,0}),DynamicObject|NoShadow);Joint(Connection(socket_,bulb_,PoseAt({0,-.055f,0}),PoseAt({0,.055f,0}),false));
    LabPhysicsLightV1 light{};light.structSize=sizeof(light);light.sceneLightIndex=uint32_t(assets.lights.size());light.body=bulb_;light.localPosition={0,-.040f,0};light.localDirection={0,-1,0};light.radius=8;light.color={1,.72f,.38f};light.power=26;light.outerCos=-.72f;light.innerCos=-.25f;lampLight_=light;
    SceneLight placeholder;placeholder.position={anchor.x,hubY-.15f,anchor.z};placeholder.direction={0,-1,0};placeholder.color={1,.72f,.38f};placeholder.power=26;placeholder.radius=8;placeholder.flags=5;placeholder.id=0x70000001;placeholder.outerCos=light.outerCos;placeholder.innerCos=light.innerCos;assets.lights.push_back(placeholder);

    const XMFLOAT3 switchAnchor{.075f,-.030f,0};
    auto sliderDesc=Description(LAB_PHYSICS_DYNAMIC,LAB_PHYSICS_SPHERE,Add({anchor.x,hubY,anchor.z},switchAnchor),{.014f,0,0},.006f,ChainLayer);sliderDesc.collisionGroup=0x200;pullSlider_=Body(sliderDesc);entities_.back().id="lamp-switch-slider";entities_.back().name="Switch slider";
    Visual(pullSlider_,uint32_t(Mesh::Sphere),Material::Steel,{.028f,.028f,.028f});
    auto switchJoint=Connection(socket_,pullSlider_,PoseAt(switchAnchor),PoseAt({0,0,0}),false);
    switchJoint.motion[1]=LAB_PHYSICS_LIMITED;switchJoint.linearLower[1]=-.045f;switchJoint.linearUpper[1]=.006f;
    switchJoint.drive[LAB_PHYSICS_DRIVE_Y]={45.f,.6f,4.f,0};Joint(switchJoint);
    constexpr uint32_t chainLinks=8;constexpr float chainPitch=.060f;
    previous=pullSlider_;
    for(uint32_t i=0;i<chainLinks;i++){
        auto d=Description(LAB_PHYSICS_DYNAMIC,LAB_PHYSICS_CAPSULE,{anchor.x+switchAnchor.x,hubY+switchAnchor.y-chainPitch*(float(i)+.5f),anchor.z},{.006f,.024f,0},.0025f,ChainLayer);
        d.shapePose.orientation=Rotation(0,0,XM_PIDIV2);d.collisionGroup=0x200;d.contactOffset=.001f;
        auto link=Body(d);entities_.back().id="lamp-chain-"+std::to_string(i);entities_.back().name="Switch chain "+std::to_string(i+1);Visual(link,Link,Material::Chain,{.045f,.058f,.045f},PoseAt({0,0,0},Rotation(0,(i&1)?XM_PIDIV2:0,0)));
        Joint(Connection(previous,link,PoseAt({0,i?-chainPitch*.5f:0,0}),PoseAt({0,chainPitch*.5f,0}),true));previous=link;
    }
    auto handleDesc=Description(LAB_PHYSICS_DYNAMIC,LAB_PHYSICS_SPHERE,{anchor.x+switchAnchor.x,hubY+switchAnchor.y-chainLinks*chainPitch-.025f,anchor.z},{.024f,0,0},.015f,ChainLayer);handleDesc.collisionGroup=0x200;pullHandle_=Body(handleDesc);entities_.back().id="lamp-pull-handle";entities_.back().name="Pull handle";
    Visual(pullHandle_,uint32_t(Mesh::Sphere),Material::Steel,{.048f,.048f,.048f});
    Joint(Connection(previous,pullHandle_,PoseAt({0,-chainPitch*.5f,0}),PoseAt({0,.025f,0}),true));

    buildingGroup_=4;
    auto baseDesc=Description(LAB_PHYSICS_STATIC,LAB_PHYSICS_BOX,{-.85f,1.55f,1.35f},{.22f,.43f,.16f},0,RoomLayer);fanBase_=Body(baseDesc);entities_.back().id="fan-base";entities_.back().name="Fan stand / housing";
    Visual(fanBase_,uint32_t(Mesh::Cylinder),Material::Steel,{.43f,.05f,.34f},PoseAt({0,-.4f,0}));
    Visual(fanBase_,uint32_t(Mesh::Box),Material::Steel,{.055f,.65f,.055f},PoseAt({0,-.06f,.08f}));
    Visual(fanBase_,uint32_t(Mesh::Cylinder),Material::Charcoal,{.44f,.06f,.44f},PoseAt({0,.32f,.055f},Rotation(XM_PIDIV2,0,0)));
    auto rotorDesc=Description(LAB_PHYSICS_DYNAMIC,LAB_PHYSICS_BOX,{-.85f,1.87f,1.27f},{.17f,.025f,.009f},.06f,ChainLayer);rotorDesc.collisionMask=0;rotorDesc.angularDamping=.003f;rotorDesc.inertia={.0003f,.0003f,.0006f};fanRotor_=Body(rotorDesc);entities_.back().id="fan-rotor";entities_.back().name="Fan rotor / blades";
    for(uint32_t blade=0;blade<3;blade++){float angle=blade*XM_2PI/3;auto q=Rotation(0,0,angle);Visual(fanRotor_,uint32_t(Mesh::Box),Material::Steel,{.07f,.18f,.014f},PoseAt(Rotated({0,.10f,0},q),q));}
    Visual(fanRotor_,uint32_t(Mesh::Sphere),Material::Charcoal,{.06f,.06f,.04f});
    auto axle=Connection(fanBase_,fanRotor_,PoseAt({0,.32f,-.08f},Rotation(0,XM_PIDIV2,0)),PoseAt({0,0,0},Rotation(0,XM_PIDIV2,0)),false);
    axle.motion[3]=LAB_PHYSICS_FREE;axle.drive[LAB_PHYSICS_DRIVE_TWIST]={0,.002f,.025f,0};fanJoint_=Joint(axle);
    // IDs of constraints refer to their declared body relation, not allocation order.
    buildingGroup_=0;
    optical_.lightIndex=lampLight_.sceneLightIndex;
    for(const auto& v:visuals_)if(v.body==bulb_){optical_.sourceId=v.id;break;}
    PublishOptical();
    Require(physics_->SetVisuals(physics_->serviceContext,scene_,visuals_.data(),uint32_t(visuals_.size()),&light,1),"Home physics_v1: physical visuals/light rejected");
    LabPopulationDescV1 population{};population.structSize=sizeof(population);population.capacity=std::max(8192u,populationCount_);population.initialCount=populationCount_;population.layer=InsectLayer;population.collisionMask=RoomLayer|ChainLayer|HandLayer;
    population.spawnCenter={-1.20f,1.95f,.20f};population.spawnHalfExtent={1.5f,.5f,1.2f};
    population.proxyMesh=Proxy;population.bodyMesh=Thorax;population.headMesh=Head;population.abdomenMesh=Abdomen;population.leftWingMesh=WingLeft;population.rightWingMesh=WingRight;
    population.bodyMaterial=uint32_t(Material::Fly);population.headMaterial=uint32_t(Material::Charcoal);population.wingMaterial=uint32_t(Material::Glue);population.flight=flight_;
    Require(physics_->CreatePopulation(physics_->serviceContext,scene_,&population),"Home physics_v1: compact GPU population required");
    Require(physics_->SetPopulationSpace(physics_->serviceContext,scene_,&populationSpace_),"Home physics_v1: flight volume rejected");
    Require(physics_->SetPopulationEffects(physics_->serviceContext,scene_,&effects_),"Home physics_v1: population effects rejected");
    flight_.impactSeconds=effects_.fleeSeconds;fog_.lightIndex=lampLight_.sceneLightIndex;Require(gpu_->SetFogSettings(gpu_->serviceContext,&fog_),"Home gpu_v1: volume settings rejected");
}
void HomePhysics::ApplyDiagnosticDefaults(){
    if(!scene_)Fail("Diagnostic defaults require an active Home scene");
    // Only in-memory state: the user's saved profiles are not modified.
    panelTheme_=LAB_TERMINAL_THEME_AMBER_V2;
    panelFace_=0;
    fog_.enabled=1;
    if(fog_.density<.06f)fog_.density=.065f;
    auto volume=fog_;
    volume.enabled=visible_?1u:0u;
    Require(gpu_->SetFogSettings(gpu_->serviceContext,&volume),"Home diagnostics: fog settings rejected");
    AddPopulation(500-int32_t(populationCount_));
    SetLampEnabled(true);
    LogEvent(sourceFrame_,"sweep.settings","theme=amber night=dark_room fog_enabled=%u fog_density=%.4f population=%u lamp=%u",
        fog_.enabled,fog_.density,populationCount_,unsigned(LampEnabled()));
}
void HomePhysics::SetDiagnosticFogEnabled(bool enabled){
    if(!gpu_||!scene_)Fail("Diagnostic fog toggle requires an active scene");
    // Transient GPU override only: do not touch user profile or fog_.
    auto settings=fog_;settings.enabled=enabled&&visible_&&fog_.enabled?1u:0u;
    Require(gpu_->SetFogSettings(gpu_->serviceContext,&settings),
        "Home diagnostic fog toggle rejected");
}
void HomePhysics::AddPopulation(int32_t delta){
    uint32_t n=uint32_t(std::clamp(int64_t(populationCount_)+delta,int64_t(0),int64_t(LAB_PHYSICS_POPULATION_MAX_V1)));
    Require(physics_->SetPopulationCount(physics_->serviceContext,scene_,n),"Home physics_v1: population batch rejected");
    flyAudioIds_.resize(n);for(uint32_t i=populationCount_;i<n;i++){
        if(nextFlyAudioId_>=0x01000000u)Fail("Home audio identity space exhausted");flyAudioIds_[i]=nextFlyAudioId_++;
    }populationCount_=n;
    Require(physics_->GetVisualProvider(physics_->serviceContext,scene_,&provider_),"Home physics_v1: population provider update rejected");Require(gpu_->SetPublicationProvider(gpu_->serviceContext,&provider_),"Home gpu_v1: resized population provider rejected");
}
void HomePhysics::SetPopulationView(XMFLOAT3 player,XMFLOAT3 origin,XMFLOAT3 direction,bool tracked){populationInput_.playerPosition=V(player);populationInput_.aimOrigin=V(origin);populationInput_.aimDirection=V(direction);populationInput_.aimTracked=tracked;}
void HomePhysics::AdjustFlight(uint32_t index,float direction){
    if(index==99){flight_={sizeof(LabFlightSettingsV1),0x76a019abu,1.4f,3.8f,.22f,1.5f,.24f,1.2f,.16f,.75f,.7f,.8f,.08f,8.f,2.5f,.000018f,.000030f,1.5f,.15f,180.f,.0035f,.25f,1.2f};Require(physics_->SetFlightSettings(physics_->serviceContext,scene_,&flight_),"Home physics_v1: reset flight rejected");effects_.fleeSeconds=flight_.impactSeconds;Require(physics_->SetPopulationEffects(physics_->serviceContext,scene_,&effects_),"Home physics_v1: reset impact duration rejected");return;}
    float* values[]{&flight_.nominalSpeed,&flight_.maxSpeed,&flight_.responseSeconds,&flight_.turnIntensity,&flight_.turnRadius,&flight_.lightAttraction,&flight_.comfortDistance,&flight_.anticipationDistance,&flight_.wander,&flight_.vertical,&flight_.avoidanceFailure,&flight_.impactSeconds,&flight_.impactMultiplier};
    static constexpr float steps[]{.1f,.2f,.02f,.1f,.02f,.1f,.02f,.05f,.05f,.05f,.01f,1.f,.25f};
    static constexpr float lo[]{0.1f,.1f,.02f,.1f,.02f,0,.02f,.02f,0,0,0,0,1};
    static constexpr float hi[]{8,12,2,8,4,8,2,4,4,4,1,120,10};
    if(index>=std::size(values))return;*values[index]=std::clamp(*values[index]+direction*steps[index],lo[index],hi[index]);
    flight_.maxSpeed=std::max(flight_.maxSpeed,flight_.nominalSpeed);flight_.anticipationDistance=std::max(flight_.anticipationDistance,flight_.comfortDistance);
    Require(physics_->SetFlightSettings(physics_->serviceContext,scene_,&flight_),"Home physics_v1: live flight setting rejected");effects_.fleeSeconds=flight_.impactSeconds;Require(physics_->SetPopulationEffects(physics_->serviceContext,scene_,&effects_),"Home physics_v1: synchronized impact duration rejected");
}
void HomePhysics::AdjustEffects(uint32_t index,float direction){
    float* values[]{&effects_.sweepRadius,&effects_.impulse,&effects_.fleeSeconds,&effects_.avoidanceRadius,&effects_.residualAversion,&effects_.shadowDensity,&effects_.shadowIntensity};
    const float steps[]{.02f,.1f,2.f,.1f,.05f,.05f,.05f},lo[]{.02f,0,0,.1f,0,0,0},hi[]{1,8,120,4,1,1,1};
    if(index>=std::size(values))return;*values[index]=std::clamp(*values[index]+direction*steps[index],lo[index],hi[index]);
    Require(physics_->SetPopulationEffects(physics_->serviceContext,scene_,&effects_),"Home physics_v1: live effects rejected");flight_.impactSeconds=effects_.fleeSeconds;Require(physics_->SetFlightSettings(physics_->serviceContext,scene_,&flight_),"Home physics_v1: synchronized flee duration rejected");
}
void HomePhysics::AdjustFog(uint32_t index,float direction){
    if(index==0)fog_.enabled=!fog_.enabled;
    else if(index==12)fog_.quality=uint32_t(std::clamp(int(fog_.quality)+(direction>0?1:-1),0,2));
    else{
        float* values[]{&fog_.density,&fog_.height,&fog_.falloff,&fog_.scattering,&fog_.anisotropy,&fog_.absorption,&fog_.turbulence,&fog_.evolution,&fog_.handResponse,&fog_.lightIntensity};
        const float steps[]{.01f,.2f,.05f,.1f,.05f,.05f,.05f,.05f,.1f,.1f},lo[]{0,0,0,0,-.8f,0,0,0,0,0},hi[]{1,4,4,4,.8f,4,1,4,4,4};
        if(index<1||index>10)return;--index;*values[index]=std::clamp(*values[index]+direction*steps[index],lo[index],hi[index]);
    }
    auto volume=fog_;volume.enabled=fog_.enabled&&visible_;Require(gpu_->SetFogSettings(gpu_->serviceContext,&volume),"Home gpu_v1: live volume settings rejected");
}
void HomePhysics::LoadConfiguration(const std::wstring& path){
    std::ifstream file{std::filesystem::path(path)};if(!file)Fail("input.ini: cannot open Home input configuration");
    HandSettings next;std::string line;
    while(std::getline(file,line)){
        auto end=line.find_first_of("#;\r");if(end!=std::string::npos)line.resize(end);
        auto trim=[](std::string v){auto first=v.find_first_not_of(" \t"),last=v.find_last_not_of(" \t");return first==std::string::npos?std::string{}:v.substr(first,last-first+1);};
        auto equals=line.find('=');if(equals==std::string::npos)continue;
        auto key=trim(line.substr(0,equals)),value=trim(line.substr(equals+1));if(key.rfind("home.",0)!=0)continue;
        char* tail{};float v=std::strtof(value.c_str(),&tail);if(value.empty()||*tail||!std::isfinite(v))Fail("input.ini: invalid Home input value");
        if(key=="home.hand_position_tau"&&v>=0&&v<=.2f)next.positionTau=v;
        else if(key=="home.hand_rotation_tau"&&v>=0&&v<=.2f)next.rotationTau=v;
        else if(key=="home.hand_max_speed"&&v>0&&v<=20)next.maxSpeed=v;
        else if(key=="home.hand_max_angular_speed"&&v>0&&v<=50)next.maxAngularSpeed=v;
        else if(key=="home.grab_radius"&&v>=.025f&&v<=.25f)next.grabRadius=v;
        else if(key=="home.grab_stiffness"&&v>0&&v<=2000)next.grabStiffness=v;
        else if(key=="home.grab_damping"&&v>=0&&v<=50)next.grabDamping=v;
        else if(key=="home.grab_max_force"&&v>0&&v<=50)next.grabMaxForce=v;
        else Fail("input.ini: unknown Home input key or value outside bounds");
    }
    handSettings_=next;if(input_)SyncTouchSources();
}
PoseActionState HomePhysics::HandState(uint32_t hand)const noexcept{
    const auto& p=handTargets_[hand&1u];PoseActionState out;
    out.pose={{p.position.x,p.position.y,p.position.z},{p.orientation.x,p.orientation.y,p.orientation.z,p.orientation.w}};out.tracked=handTracked_[hand&1u];return out;
}
void HomePhysics::ReleaseHand(uint32_t hand,bool destroy){
    if(grips_[hand]){Require(physics_->DestroyJoint(physics_->serviceContext,scene_,grips_[hand]),"Home physics_v1: grip release rejected");grips_[hand]=0;}
    if(destroy&&hands_[hand]){Require(physics_->DestroyBody(physics_->serviceContext,scene_,hands_[hand]),"Home physics_v1: hand proxy detach rejected");hands_[hand]=0;handColliding_[hand]=false;}
}
void HomePhysics::UpdateHands(const LabInputSnapshotV1& input,double dt,bool reset,bool sampled,std::vector<LabPhysicsCommandV1>& commands){
    auto sample=[&](LabInputActionHandleV1 action,uint32_t hand)->const LabInputSampleV1*{for(uint32_t i=0;i<input.sampleCount;i++)if(input.samples[i].controlId==action&&input.samples[i].sourceId==hand)return &input.samples[i];return nullptr;};
    auto down=[](const LabInputSampleV1* s){return s&&(s->flags&LABOVR_INPUT_SAMPLE_ACTIVE_V1)&&(s->flags&LABOVR_INPUT_SAMPLE_DOWN_V1);};
    for(uint32_t hand=0;hand<2;hand++){
        const LabInputPoseStateV1* pose{};for(uint32_t i=0;i<input.poseCount;i++)if(input.poses[i].controlId==handPose_&&input.poses[i].sourceId==hand){pose=&input.poses[i];break;}
        bool tracked=pose&&(pose->flags&LABOVR_INPUT_SAMPLE_TRACKED_V1)&&input.focused;
        auto* touch=sample(physicalAction_,hand);auto* grab=sample(grabAction_,hand);
        bool touching=down(touch),grabbing=down(grab);
        auto& sweep=sweeps_.hand[hand];sweep={};
        if(tracked){
            XMFLOAT3 rawPosition{pose->position[0],pose->position[1],pose->position[2]};
            XMFLOAT3 rawVelocity{pose->velocity[0],pose->velocity[1],pose->velocity[2]};
            bool finite=std::isfinite(rawVelocity.x)&&std::isfinite(rawVelocity.y)&&std::isfinite(rawVelocity.z);
            bool continuous=sweepTracked_[hand]&&!reset&&Length(Sub(rawPosition,sweepLast_[hand]))<.35f&&finite&&Length(rawVelocity)<20;
            if(continuous){
                float blend=1-std::exp(-float(dt)/.025f);
                sweepVelocity_[hand]=Add(sweepVelocity_[hand],Scale(Sub(rawVelocity,sweepVelocity_[hand]),blend));
                float speed=Length(sweepVelocity_[hand]);if(speed>12)sweepVelocity_[hand]=Scale(sweepVelocity_[hand],12/speed);
            }else sweepVelocity_[hand]={};
            sweep.position=V(rawPosition);sweep.previous=V(continuous?sweepLast_[hand]:rawPosition);
            sweep.velocity=V(sweepVelocity_[hand]);sweep.tracked=1;sweepLast_[hand]=rawPosition;
        }else sweepVelocity_[hand]={};
        sweepTracked_[hand]=tracked;
        if(frozen_){
            // Tracking remains live, but no actor/joint topology mutates while
            // Direct GPU indices are pinned for the frozen editor session.
            if(tracked){LabPoseV1 raw{{pose->position[0],pose->position[1],pose->position[2]},{pose->orientation[0],pose->orientation[1],pose->orientation[2],pose->orientation[3]}};
                if(!handTracked_[hand]||reset)handTargets_[hand]=raw;
                else{float blend=handSettings_.positionTau>0?1-std::exp(-float(dt)/handSettings_.positionTau):1;
                    handTargets_[hand].position=V(Add(V(handTargets_[hand].position),Scale(Sub(V(raw.position),V(handTargets_[hand].position)),blend)));
                    auto& q=handTargets_[hand].orientation;XMFLOAT4 filtered;XMStoreFloat4(&filtered,XMQuaternionSlerp(XMVectorSet(q.x,q.y,q.z,q.w),XMVectorSet(raw.orientation.x,raw.orientation.y,raw.orientation.z,raw.orientation.w),blend));q={filtered.x,filtered.y,filtered.z,filtered.w};}
            }handTracked_[hand]=tracked;continue;
        }
        if(!tracked){ReleaseHand(hand,true);handTracked_[hand]=false;handBlocked_[hand]=true;continue;}
        LabPoseV1 raw{{pose->position[0],pose->position[1],pose->position[2]},{pose->orientation[0],pose->orientation[1],pose->orientation[2],pose->orientation[3]}};
        bool jumped=handTracked_[hand]&&Length(Sub(V(raw.position),V(handTargets_[hand].position)))>.45f;
        if(reset||jumped){ReleaseHand(hand,true);handTracked_[hand]=false;handBlocked_[hand]=true;}
        // Capacitive rest surfaces may remain touched throughout normal use.
        // Rearm grab on grip release; touching must not lock physical hands out.
        if(!grabbing)handBlocked_[hand]=false;
        if(!handTracked_[hand])handTargets_[hand]=raw;
        else{
            auto& target=handTargets_[hand];XMFLOAT3 delta=Sub(V(raw.position),V(target.position));float distance=Length(delta);
            float positionBlend=handSettings_.positionTau>0?1.f-std::exp(-float(dt)/handSettings_.positionTau):1.f;
            if(distance>1e-6f)positionBlend=std::min(positionBlend,handSettings_.maxSpeed*float(dt)/distance);
            target.position=V(Add(V(target.position),Scale(delta,positionBlend)));
            auto a=XMVectorSet(target.orientation.x,target.orientation.y,target.orientation.z,target.orientation.w),b=XMVectorSet(raw.orientation.x,raw.orientation.y,raw.orientation.z,raw.orientation.w);
            float angle=2.f*std::acos(std::clamp(std::abs(XMVectorGetX(XMQuaternionDot(a,b))),0.f,1.f));
            float rotationBlend=handSettings_.rotationTau>0?1.f-std::exp(-float(dt)/handSettings_.rotationTau):1.f;
            if(angle>1e-5f)rotationBlend=std::min(rotationBlend,handSettings_.maxAngularSpeed*float(dt)/angle);
            XMFLOAT4 q;XMStoreFloat4(&q,XMQuaternionNormalize(XMQuaternionSlerp(a,b,rotationBlend)));target.orientation={q.x,q.y,q.z,q.w};
        }
        handTracked_[hand]=true;
        bool canInteract=visible_&&!handBlocked_[hand];
        bool enabled=visible_&&touching&&!reset&&!jumped;
        if(!canInteract||!grabbing)ReleaseHand(hand,false);
        if(!hands_[hand]){
            auto d=Description(LAB_PHYSICS_KINEMATIC,LAB_PHYSICS_BOX,V(handTargets_[hand].position),{.038f,.020f,.071f},1,HandLayer);
            d.pose=handTargets_[hand];d.shapePose.position={0,0,.026f};d.collisionMask=ChainLayer|InsectLayer;d.contactOffset=.002f;
            hands_[hand]=Body(d);entities_.pop_back();handColliding_[hand]=true;
        }
        if(handColliding_[hand]!=enabled){Require(physics_->SetBodyCollisionEnabled(physics_->serviceContext,scene_,hands_[hand],enabled?1u:0u),"Home physics_v1: hand collision toggle rejected");handColliding_[hand]=enabled;}
        if(canInteract&&grabbing&&!grips_[hand]&&!grips_[1-hand]&&sampled&&grab&&(grab->flags&LABOVR_INPUT_SAMPLE_PRESSED_V1)){
            const auto& handle=states_[3];XMFLOAT3 offset=Sub(V(handle.pose.position),V(handTargets_[hand].position));
            if(handle.body==pullHandle_&&Length(offset)<=handSettings_.grabRadius){
                const auto& q=handTargets_[hand].orientation;XMFLOAT3 local;XMStoreFloat3(&local,XMVector3Rotate(XMLoadFloat3(&offset),XMQuaternionInverse(XMVectorSet(q.x,q.y,q.z,q.w))));
                auto joint=Connection(hands_[hand],pullHandle_,PoseAt(local),PoseAt({0,0,0}),false);
                for(auto& motion:joint.motion)motion=LAB_PHYSICS_FREE;
                for(uint32_t i=0;i<3;i++)joint.drive[i]={handSettings_.grabStiffness,handSettings_.grabDamping,handSettings_.grabMaxForce,0};
                grips_[hand]=Joint(joint);connections_.pop_back();
            }
        }
        auto command=Command(LAB_PHYSICS_KINEMATIC_TARGET,hands_[hand],{});command.target=handTargets_[hand];commands.push_back(command);
    }
}
void HomePhysics::Update(uint64_t frame,double now,std::span<const SceneLight> attractive){
    if(!scene_)return;
    LabInputSnapshotV1 input{};input.version=1;input.structSize=sizeof(input);Require(input_->GetSnapshot(input_->serviceContext,&input),"Home input_v1: snapshot unavailable");
    std::vector<LabPhysicsCommandV1> commands;commands.reserve(4);
    const bool trackingReset=(trackingRevision_&&trackingRevision_!=input.trackingRevision)||(lastUpdateSeconds_>0&&(now<=lastUpdateSeconds_||now-lastUpdateSeconds_>.75));
    double dt=lastUpdateSeconds_>0?std::clamp(now-lastUpdateSeconds_,.001,.05):1./72.;trackingRevision_=input.trackingRevision;lastUpdateSeconds_=now;
    LabPhysicsSnapshotV1 snapshot{sizeof(snapshot),uint32_t(states_.size()),states_.data()};
    bool fresh=physics_->PollSnapshot(physics_->serviceContext,scene_,&snapshot)!=0;PollPhysicalSources();
    auto previousRequest=captureStatus_.requestId;auto previousState=captureStatus_.state;
    captureStatus_.structSize=sizeof(captureStatus_);
    if(gpu_->GetCaptureStatus(gpu_->serviceContext,&captureStatus_)&&captureStatus_.requestId&&
       (captureStatus_.requestId!=previousRequest||captureStatus_.state!=previousState))status_=captureStatus_.message;
    if(fresh){sourceFrame_=snapshot.sourceFrame;stateSeconds_=snapshot.simulationSeconds;simulationSeconds_=snapshot.simulationSeconds;if(states_[4].body==fanRotor_)fanActualRpm_=std::clamp(Length(V(states_[4].angularVelocity))*60.f/XM_2PI,0.f,2100.f);}
    bool sampled=sourceFrame_&&sourceFrame_<=frame&&frame-sourceFrame_<6;
    UpdateHands(input,dt,trackingReset,sampled,commands);
    if(fresh&&visible_&&!frozen_&&states_[1].body==socket_&&states_[2].body==pullSlider_){
        // Measure the physical slider in the socket's frame: moving or swinging
        // the whole lamp cannot impersonate a pull of its switch chain.
        auto offset=Sub(V(states_[2].pose.position),V(states_[1].pose.position));const auto& q=states_[1].pose.orientation;
        auto local=Rotated(offset,{-q.x,-q.y,-q.z,q.w});float travel=-local.y-.030f;
        if(pullArmed_&&travel>.027f){SetLampEnabled(!LampEnabled());pullArmed_=false;}
        else if(travel<.012f)pullArmed_=true;
    }
    Require(physics_->SetPopulationHands(physics_->serviceContext,scene_,&sweeps_),"Home physics_v1: hand sweeps rejected");
    LabFogInputV1 fogInput{sizeof(fogInput),visible_};std::copy_n(sweeps_.hand,2,fogInput.hand);
    Require(gpu_->SetFogInput(gpu_->serviceContext,&fogInput),"Home gpu_v1: volume hand input rejected");
    // Hiding the home layer removes the observer, not its living simulation.
    populationInput_.hands[0]=hands_[0];populationInput_.hands[1]=hands_[1];populationInput_.enabled=1;
    Require(physics_->SetPopulationInput(physics_->serviceContext,scene_,&populationInput_),"Home physics_v1: tracked population input rejected");
    physics_->PollPopulation(physics_->serviceContext,scene_,&population_);
    UpdateFan(frame);
    if(!commands.empty())Require(physics_->SubmitCommands(physics_->serviceContext,scene_,commands.data(),uint32_t(commands.size())),"Home physics_v1: grouped hand/flight commands rejected");
}
}
