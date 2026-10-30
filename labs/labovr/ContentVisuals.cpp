#include "ClientVisuals.h"
#include "ContentIds.h"
#include "LabInputMapping.h"
namespace lab {
namespace {
void AddObject(RenderScene& r,const Pose& previous,const Pose& current,XMFLOAT3 scale,Mesh mesh,Material material,uint32_t id,uint32_t flags=0){r.objects.push_back({previous,current,scale,uint32_t(mesh),uint32_t(material),id,flags});++r.count;}
void Part(RenderScene& r,const Pose& previous,const Pose& current,XMFLOAT3 local,XMFLOAT3 scale,Mesh mesh,Material material,uint32_t id){Pose a=previous,b=current;a.p=Transform(local,previous);b.p=Transform(local,current);AddObject(r,a,b,scale,mesh,material,id,DynamicObject);}
}
void AppendClientHands(RenderScene& r,const FrameInput& input,const std::array<PoseActionState,2>* hands){
    for(uint32_t i=0;i<2;i++){const auto& hand=hands?(*hands)[i]:input.PoseState(StandardVrActions().handPose,i);if(hand.tracked){float grab=input.Analog(StandardVrActions().grab,i);Part(r,hand.pose,hand.pose,{0,0,.012f},{.071f,.035f,.10f},Mesh::Box,i?Material::HandRight:Material::HandLeft,0xa0000000u+i);for(uint32_t finger=0;finger<4;finger++){float bend=grab*.045f;Part(r,hand.pose,hand.pose,{(float(finger)-1.5f)*.016f,-bend*.45f,.077f-bend},{.013f,.016f,.054f},Mesh::Box,i?Material::HandRight:Material::HandLeft,0xa0000010u+i*4+finger);}}}
}
}
