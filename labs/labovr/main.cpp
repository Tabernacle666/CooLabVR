#include "Core.h"
#include "ContentCatalog.h"
#include "PluginHost.h"
#include "PluginLoader.h"
#include "PluginWorldAdapter.h"
#include "ClientAssets.h"
#include "ClientLayers.h"
#include "HomeWorld.h"
#include "LabInputMapping.h"
#include "LabAudio.h"
#include "PerformanceCapture.h"
#include "XR.h"
#include "Graphics.h"
#include "PhysicsRuntime.h"
#include "Audio.h"
#include "Jobs.h"
#include "SessionLog.h"
#include "BuildConfig.h"
#include "BuildVersion.h"
#include "World.h"
#include <shellapi.h>
#include <memory>
#include <cwchar>
#include <filesystem>
namespace lab {
const CoreIdentity& LaboVRIdentity() noexcept {
    static const CoreIdentity identity{
        .applicationName="LaboVR",
        .engineName="LaboVR",
        .version=LAB_ENGINE_VERSION,
        .versionW=LAB_ENGINE_VERSION_W,
        .cacheNamespaceW=L"LaboVR",
        .diagnosticLabel="LaboVR",
        .diagnosticLabelW=L"LaboVR",
        .pipelineCacheIdentity=LAB_PIPELINE_ABI,
        .telemetryProvider=nullptr
    };
    return identity;
}
struct ComScope {ComScope(){Hr(CoInitializeEx(nullptr,COINIT_MULTITHREADED),"COM");}~ComScope(){CoUninitialize();}};
struct RunOptions {
    std::wstring scene;
    bool gpuValidation{};
};
class HostGpuStream final:public GpuStream {
    PluginHost& host_;
public:
    explicit HostGpuStream(PluginHost& host):host_(host){}
    GpuWorldDomain Domain()const noexcept override{return LABOVR_GPU_DOMAIN_MESH_SOLID_V1;}
    GpuPublication Acquire()override{return host_.AcquireGpuPublication();}
    void Release(const GpuPublication& publication)override{host_.ReleaseGpuPublication(publication);}
};
int RenderThread(Channels& io,const RunOptions& options) {
    wchar_t threadName[96];swprintf_s(threadName,L"%ls render",GetCoreIdentity().diagnosticLabelW);SetThreadDescription(GetCurrentThread(),threadName);ComScope com;JobSystem jobs;jobs.Start();
    const auto inputConfiguration=AssetPath(L"input.ini");
    InputSystem inputSystem;DeclareStandardVrInputActions(inputSystem);inputSystem.LoadConfiguration(inputConfiguration);StandardVrInput clientInput;clientInput.LoadConfiguration(inputConfiguration);clientInput.SetNavigationOptions(true,true);Graphics graphics;XR xr;ClientAudio audioSignals;Audio audio;PhysicsRuntime physics;PluginHost homeHost;PluginHost pluginHost;pluginHost.BindChannels(io);pluginHost.BindInputSystem(inputSystem);
    WorldLifecycle worlds;worlds.Services().Register(graphics);worlds.Services().Register(audio);worlds.Services().Register(xr);worlds.Services().Register(jobs);worlds.Services().Register(io);worlds.Services().Register(inputSystem);worlds.Services().Register(clientInput);worlds.Services().Register(pluginHost);HomeWorld home;ClientLayers presentation;PluginLoader pluginLoader;std::unique_ptr<LoadedPlugin> activeModule;std::unique_ptr<PluginWorldAdapter> activePlugin;auto worldCatalog=DiscoverWorldCatalog();std::vector<std::string> worldNames;for(const auto& entry:worldCatalog)worldNames.emplace_back(entry.name);home.SetWorldNames(std::move(worldNames));
    xr.InitializeInstance({GetCoreIdentity().applicationName,GetCoreIdentity().engineName,140},inputSystem,clientInput.Mapping());graphics.Initialize(xr.GraphicsRequirements(),options.gpuValidation);pluginHost.BindGraphics(graphics);physics.Initialize(graphics.Device());pluginHost.BindPhysics(physics);
    audio.InitializeService(io,nullptr,audioSignals.Provider());homeHost.BindAudio(audio);pluginHost.BindAudio(audio);
    homeHost.BindChannels(io);homeHost.BindInputSystem(inputSystem);homeHost.BindGraphics(graphics);homeHost.BindPhysics(physics);
    const std::array<std::string,6> homeServices{"physics_v1","input_v1","audio_v1","gpu_v1","gpu_interop_v1","storage_v1"};homeHost.ConfigureWorldServices("home",{},homeServices);
    LabHostApiV1 homeApi=homeHost.Api();worlds.Services().Register(homeApi);home.LoadConfiguration(inputConfiguration);worlds.LoadPersistent(home);HostGpuStream homeStream(homeHost);
    xr.InitializeSession(graphics.Device(),graphics.Queue());presentation.Set(home.Contributions());graphics.Configure(xr,home.Scene(),jobs,presentation.Contributions());audio.LoadScene(home.Scene());audio.Start();graphics.AttachStream(homeStream);
    PerformanceCapture performance;
    std::string activeWorldId="home",activeWorldName="Home";
    bool menuVisible=true,activeWorldRetainsHomeAmbient=true;
    std::error_code inputConfigurationError;
    auto inputConfigurationWrite=std::filesystem::last_write_time(inputConfiguration,inputConfigurationError);double inputConfigurationCheckAt{};
    auto composedScene=[&](){SceneData scene=home.Scene();if(!activeWorldRetainsHomeAmbient){scene.objects.clear();scene.lights.clear();}if(activePlugin&&activePlugin->Loaded())AppendClientScene(scene,activePlugin->Scene());return scene;};
    while(!io.stop.load(std::memory_order_relaxed)&&!xr.ExitRequested()) {
        graphics.PumpCaptures();xr.PollEvents();if(!xr.Running()){Sleep(5);continue;}
        XRFrame frame;if(!xr.BeginFrame(frame))continue;
        const double activeFrameBegin=QpcNowSeconds();
        if(activeFrameBegin>=inputConfigurationCheckAt){
            inputConfigurationCheckAt=activeFrameBegin+1.;auto modified=std::filesystem::last_write_time(inputConfiguration,inputConfigurationError);
            if(!inputConfigurationError&&modified!=inputConfigurationWrite){inputSystem.LoadConfiguration(inputConfiguration);clientInput.LoadConfiguration(inputConfiguration);home.LoadConfiguration(inputConfiguration);inputConfigurationWrite=modified;}
        }
        performance.BeginFrame(frame,activeWorldId,activeWorldName,options.scene,graphics,io);
        io.input.write()=frame.input;io.input.publish();double now=frame.input.targetDisplayQpc?QpcSeconds(frame.input.targetDisplayQpc):frame.input.time;if(frame.input.Pressed(StandardVrActions().menu,0))menuVisible=!menuVisible;home.SetMenuVisible(menuVisible);pluginHost.SetInputCaptured(menuVisible&&activePlugin!=nullptr);if(activePlugin&&activePlugin->Active()){
            auto scope=performance.Measure(CpuStage::WorldFrame);
            activePlugin->Frame(frame.input.frameId,now);
        }
        std::span<const SceneLight> attractive;if(activePlugin&&activePlugin->Active())attractive=activePlugin->AttractiveLights();
        {
            auto scope=performance.Measure(CpuStage::HomeUpdate);
            home.Update(frame.input,now,attractive);
        }
        HomeCommand command=home.ConsumeCommand();
        if(command.kind==HomeCommandKind::NewSession){activeWorldId="home";activeWorldName="Home";menuVisible=true;activeWorldRetainsHomeAmbient=true;home.SetMenuVisible(true);pluginHost.SetInputCaptured(false);worlds.UnloadActive();activePlugin.reset();activeModule.reset();pluginHost.ClearWorldServices();clientInput.SetNavigationOptions(true,true);graphics.WaitIdle();worlds.ResetPersistent(home);home.SetAmbientVisible(true);presentation.Set(home.Contributions());SceneData scene=home.Scene();graphics.WaitIdle();graphics.ReplaceScene(scene,presentation.Contributions());audio.LoadScene(scene);}
        else if(command.kind==HomeCommandKind::LoadWorld&&command.world<worldCatalog.size()){
            const auto& selected=worldCatalog[command.world];menuVisible=false;activeWorldRetainsHomeAmbient=selected.navigation.retainHomeAmbient;home.SetMenuVisible(false);home.SetAmbientVisible(activeWorldRetainsHomeAmbient);pluginHost.SetInputCaptured(false);LogEvent(frame.input.frameId,"plugin.transition","stage=begin world=%u",command.world);
            worlds.UnloadActive();activePlugin.reset();activeModule.reset();pluginHost.ClearWorldServices();
            clientInput.SetNavigationOptions(selected.navigation.smoothLocomotion,selected.navigation.heightAdjust);
            pluginHost.ConfigureWorldServices(selected.id,selected.packageRoot,selected.requiredServices);
            activeModule=pluginLoader.Load(selected);
            LogEvent(frame.input.frameId,"plugin.transition","stage=dll_loaded");
            activePlugin=std::make_unique<PluginWorldAdapter>(activeModule->Api(),pluginHost.Api(),selected.packageRoot.wstring(),options.scene,selected.requiredInputActions);
            LogEvent(frame.input.frameId,"plugin.transition","stage=adapter_created");
            worlds.ReplaceActive(*activePlugin);
            LogEvent(frame.input.frameId,"plugin.transition","stage=loaded scene_objects=%u",uint32_t(activePlugin->Scene().objects.size()));
            activePlugin->Activate(uint32_t(home.Scene().meshes.ranges.size()),uint32_t(home.Scene().materials.size()),activeWorldRetainsHomeAmbient?uint32_t(home.Scene().lights.size()):0u);
            LogEvent(frame.input.frameId,"plugin.transition","stage=activated");
            presentation.Set(home.Contributions(),activePlugin->Contributions());SceneData scene=composedScene();
            LogEvent(frame.input.frameId,"plugin.transition","stage=scene_composed objects=%u",uint32_t(scene.objects.size()));
            graphics.WaitIdle();
            LogEvent(frame.input.frameId,"plugin.transition","stage=gpu_idle");
            graphics.ReplaceScene(scene,presentation.Contributions());
            LogEvent(frame.input.frameId,"plugin.transition","stage=scene_replaced");
            audio.LoadScene(scene);
            activeWorldId=selected.id;activeWorldName=selected.name;
            LogEvent(frame.input.frameId,"plugin.transition","stage=complete");
        }
        else if(command.kind==HomeCommandKind::Quit)io.stop=true;
        {auto scope=performance.Measure(CpuStage::PhysicsAdvance);physics.Advance(now,frame.input.frameId);}
        home.PublishMenu();
        {
            auto scope=performance.Measure(CpuStage::AudioAndEvents);
            auto& audioFrame=io.audio.write();home.FillAudio(audioFrame,frame.input,now);homeHost.AppendAudio(audioFrame);pluginHost.AppendAudio(audioFrame);io.audio.publish();
            HapticEvent h;while(io.haptics.pop(h))xr.Haptic(h);PhysicsEvent event;while(io.physicsEvents.pop(event)){LogEvent(event.inputFrameId,"physics.event","kind=%u a=%llu b=%llu hand=%u strength=%.4f xyz=%.4f,%.4f,%.4f",uint32_t(event.kind),static_cast<unsigned long long>(event.a.value),static_cast<unsigned long long>(event.b.value),event.hand,event.strength,event.position.x,event.position.y,event.position.z);}
        }
        if(frame.render){
            bool prepared;
            {
                auto scope=performance.Measure(CpuStage::GraphicsPrepare);
                prepared=graphics.Prepare(frame.input);
            }
            if(prepared){
                bool acquired;
                {
                    auto scope=performance.Measure(CpuStage::LateLocateAcquire);
                    xr.LocateLate(frame);
                    acquired=frame.tracked&&xr.AcquireSwapchains(frame);
                }
                if(acquired){
                    auto scope=performance.Measure(CpuStage::GraphicsRender);
                    graphics.Render(frame);
                }
            }
        }
        {
            auto scope=performance.Measure(CpuStage::XrEndFrame);
            xr.EndFrame(frame);
        }
        double activeCpuMs=(QpcNowSeconds()-activeFrameBegin)*1000;
        double displayBudgetMs=double(frame.displayPeriod)/1'000'000.0;
        LogEvent(frame.input.frameId,"vr.frame","render_requested=%u tracked=%u submitted=%u abandoned=%u active_cpu_ms=%.4f display_budget_ms=%.4f cpu_over_budget=%u",unsigned(frame.render),unsigned(frame.tracked),unsigned(frame.submitted),unsigned(frame.render&&!frame.submitted),activeCpuMs,displayBudgetMs,unsigned(displayBudgetMs>0&&activeCpuMs>displayBudgetMs));
        performance.EndFrame(frame,graphics,xr,io);
    }
    io.stop=true;graphics.WaitIdle();graphics.PumpCaptures();graphics.DetachStream(homeStream);worlds.UnloadAll();activePlugin.reset();activeModule.reset();pluginHost.ClearWorldServices();homeHost.ClearWorldServices();physics.Shutdown();audio.Stop();graphics.WaitIdle();audio.UnloadScene();graphics.UnloadScene();jobs.Stop();
    const auto validation=graphics.ValidationState();bool clean=!validation.deviceRemoved&&!validation.errors&&!validation.warnings;

    return options.gpuValidation&&!clean?2:0;
}
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
#if LABOVR_DIAGNOSTIC_TRACE
    using lab::LogEvent;
#endif
    lab::ConfigureCore(lab::LaboVRIdentity());lab::RunOptions options;int count=0;auto* args=CommandLineToArgvW(GetCommandLineW(),&count);if(!args)lab::Fail("Cannot parse command line");
    if(args){for(int i=1;i<count;i++)if(wcscmp(args[i],L"--log")==0&&i+1<count){lab::StartSessionLog(args[i+1]);break;}LogEvent(0,"startup.build","engine=%s pipeline_abi=%s cuda_expected=sm_%u toolkit=%s",LAB_ENGINE_VERSION,LAB_PIPELINE_ABI,LAB_CUDA_ARCHITECTURE,LAB_CUDA_TOOLKIT_VERSION);
    for(int i=1;i<count;i++){if(wcscmp(args[i],L"--log")==0&&i+1<count){++i;}else if(wcscmp(args[i],L"--scene")==0&&i+1<count)options.scene=args[++i];else if(wcscmp(args[i],L"--gpu-validation")==0)options.gpuValidation=true;else lab::Fail("Unknown or incomplete option");}LocalFree(args);}
    int result=0;auto io=std::make_unique<lab::Channels>();std::thread render([&]{result=lab::RenderThread(*io,options);});while(!io->stop.load(std::memory_order_relaxed)){MSG message;while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){if(message.message==WM_QUIT)io->stop=true;TranslateMessage(&message);DispatchMessageW(&message);}if(GetAsyncKeyState(VK_ESCAPE)&0x8000)io->stop=true;Sleep(5);}render.join();LogEvent(0,"session.end","clean_shutdown=1 result=%d",result);lab::StopSessionLog();return result;
}
