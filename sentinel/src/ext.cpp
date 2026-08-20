#if defined(DM_PLATFORM_WINDOWS) && !defined(WIN32_LEAN_AND_MEAN)
#define WIN32_LEAN_AND_MEAN
#endif

#define LIB_NAME "Sentinel"
#define MODULE_NAME "sentinel_native"

#include <dmsdk/sdk.h>
#include <dmsdk/graphics/graphics.h>

#include <assert.h>
#include <stdio.h>
#include <string.h>

#if defined(DM_PLATFORM_WINDOWS)
#include <windows.h>
#include <GL/gl.h>
#include <dxgi.h>
#elif defined(DM_PLATFORM_LINUX)
#include <dirent.h>
#include <stdio.h>
#include <unistd.h>
#include <GL/gl.h>
#elif defined(DM_PLATFORM_OSX)
#include <OpenGL/gl3.h>
#endif

#if defined(DM_PLATFORM_OSX)
extern "C" bool SentinelPushMacOSMetalGpuInfo(lua_State* L, bool push_api_fields);
#endif

static void PushStringField(lua_State* L, const char* key, const char* value)
{
    if (value && value[0] != '\0')
    {
        lua_pushstring(L, value);
        lua_setfield(L, -2, key);
    }
}

static void PushIntegerField(lua_State* L, const char* key, lua_Integer value)
{
    if (value > 0)
    {
        lua_pushinteger(L, value);
        lua_setfield(L, -2, key);
    }
}

static void PushHexField(lua_State* L, const char* key, uint32_t value, uint32_t width)
{
    if (value == 0)
    {
        return;
    }

    char buffer[32];
    snprintf(buffer, sizeof(buffer), "0x%0*x", width, value);
    PushStringField(L, key, buffer);
}

static const char* AdapterFamilyToApiType(dmGraphics::AdapterFamily family)
{
    switch (family)
    {
    case dmGraphics::ADAPTER_FAMILY_OPENGL:
        return "OpenGL";
    case dmGraphics::ADAPTER_FAMILY_OPENGLES:
        return "OpenGL ES";
    case dmGraphics::ADAPTER_FAMILY_VULKAN:
        return "Vulkan";
    case dmGraphics::ADAPTER_FAMILY_DIRECTX:
        return "DirectX 12";
    case dmGraphics::ADAPTER_FAMILY_METAL:
        return "Metal";
    case dmGraphics::ADAPTER_FAMILY_WEBGPU:
        return "WebGPU";
    default:
        return 0;
    }
}

#if defined(DM_PLATFORM_WINDOWS) || defined(DM_PLATFORM_LINUX) || defined(DM_PLATFORM_OSX)
static bool CollectOpenGLGpuInfo(lua_State* L, dmGraphics::AdapterFamily family)
{
    const char* api_type = AdapterFamilyToApiType(family);
    if (api_type)
    {
        PushStringField(L, "api_type", api_type);
    }

    const char* renderer = (const char*) glGetString(GL_RENDERER);
    const char* version = (const char*) glGetString(GL_VERSION);
    const char* vendor = (const char*) glGetString(GL_VENDOR);
    const char* shading_language_version = (const char*) glGetString(GL_SHADING_LANGUAGE_VERSION);

    PushStringField(L, "name", renderer);
    PushStringField(L, "renderer", renderer);
    PushStringField(L, "version", version);
    PushStringField(L, "vendor_name", vendor);
    PushStringField(L, "graphics_shader_level", shading_language_version);

    return renderer || version || vendor || shading_language_version;
}
#endif

#if defined(DM_PLATFORM_WINDOWS)
static bool WideToUtf8(const wchar_t* source, char* buffer, int buffer_size)
{
    if (!source || !buffer || buffer_size <= 0)
    {
        return false;
    }

    int length = WideCharToMultiByte(CP_UTF8, 0, source, -1, buffer, buffer_size, 0, 0);
    if (length <= 0)
    {
        buffer[0] = '\0';
        return false;
    }

    buffer[buffer_size - 1] = '\0';
    return true;
}

static const char* DxgiVendorIdToName(uint32_t vendor_id)
{
    switch (vendor_id)
    {
    case 0x1002:
        return "AMD";
    case 0x10DE:
        return "NVIDIA";
    case 0x8086:
        return "Intel";
    case 0x1414:
        return "Microsoft";
    default:
        return "Unknown";
    }
}

static bool CollectWindowsDxgiGpuInfo(lua_State* L, bool set_api_type)
{
    IDXGIFactory1* factory = 0;
    HRESULT hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**) &factory);
    if (FAILED(hr) || !factory)
    {
        return false;
    }

    bool has_values = false;
    for (UINT i = 0; ; ++i)
    {
        IDXGIAdapter1* adapter = 0;
        hr = factory->EnumAdapters1(i, &adapter);
        if (hr == DXGI_ERROR_NOT_FOUND)
        {
            break;
        }
        if (FAILED(hr) || !adapter)
        {
            continue;
        }

        DXGI_ADAPTER_DESC1 desc;
        memset(&desc, 0, sizeof(desc));
        hr = adapter->GetDesc1(&desc);
        if (SUCCEEDED(hr) && (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) == 0)
        {
            char name[256];
            if (WideToUtf8(desc.Description, name, sizeof(name)))
            {
                PushStringField(L, "name", name);
                PushStringField(L, "renderer", name);
            }
            if (set_api_type)
            {
                PushStringField(L, "api_type", "DirectX 12");
            }
            PushStringField(L, "vendor_name", DxgiVendorIdToName(desc.VendorId));
            PushHexField(L, "vendor_id", desc.VendorId, 4);
            PushHexField(L, "device_id", desc.DeviceId, 4);
            PushHexField(L, "id", desc.DeviceId, 4);
            PushIntegerField(L, "memory_size", (lua_Integer) (desc.DedicatedVideoMemory / (1024ULL * 1024ULL)));
            has_values = true;
            adapter->Release();
            break;
        }

        adapter->Release();
    }

    factory->Release();
    return has_values;
}
#endif

#if defined(DM_PLATFORM_LINUX)
static bool ReadFirstLine(const char* path, char* buffer, int buffer_size)
{
    FILE* file = fopen(path, "r");
    if (!file)
    {
        return false;
    }

    bool ok = fgets(buffer, buffer_size, file) != 0;
    fclose(file);
    if (!ok)
    {
        return false;
    }

    size_t length = strlen(buffer);
    while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r'))
    {
        buffer[--length] = '\0';
    }
    return length > 0;
}

static bool CollectLinuxDrmGpuInfo(lua_State* L)
{
    DIR* dir = opendir("/sys/class/drm");
    if (!dir)
    {
        return false;
    }

    bool has_values = false;
    struct dirent* entry = 0;
    while ((entry = readdir(dir)) != 0)
    {
        if (strncmp(entry->d_name, "card", 4) != 0)
        {
            continue;
        }

        char vendor_path[256];
        char device_path[256];
        snprintf(vendor_path, sizeof(vendor_path), "/sys/class/drm/%s/device/vendor", entry->d_name);
        snprintf(device_path, sizeof(device_path), "/sys/class/drm/%s/device/device", entry->d_name);

        char vendor_id[32];
        char device_id[32];
        bool has_vendor = ReadFirstLine(vendor_path, vendor_id, sizeof(vendor_id));
        bool has_device = ReadFirstLine(device_path, device_id, sizeof(device_id));
        if (!has_vendor && !has_device)
        {
            continue;
        }

        PushStringField(L, "vendor_id", has_vendor ? vendor_id : 0);
        PushStringField(L, "device_id", has_device ? device_id : 0);
        PushStringField(L, "id", has_device ? device_id : 0);
        has_values = true;
        break;
    }

    closedir(dir);
    return has_values;
}
#endif

static int GetGpuInfo(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);

    lua_newtable(L);

    bool has_values = false;
    bool has_backend_values = false;
    dmGraphics::AdapterFamily family = dmGraphics::GetInstalledAdapterFamily();
    const char* api_type = AdapterFamilyToApiType(family);
    if (api_type)
    {
        PushStringField(L, "api_type", api_type);
        has_values = true;
    }

#if defined(DM_PLATFORM_WINDOWS) || defined(DM_PLATFORM_LINUX) || defined(DM_PLATFORM_OSX)
    if (family == dmGraphics::ADAPTER_FAMILY_OPENGL || family == dmGraphics::ADAPTER_FAMILY_OPENGLES)
    {
        has_backend_values = CollectOpenGLGpuInfo(L, family) || has_backend_values;
        has_values = has_backend_values || has_values;
    }
#endif

#if defined(DM_PLATFORM_WINDOWS)
    if (family == dmGraphics::ADAPTER_FAMILY_DIRECTX || !has_backend_values)
    {
        has_backend_values = CollectWindowsDxgiGpuInfo(L, family == dmGraphics::ADAPTER_FAMILY_DIRECTX) || has_backend_values;
        has_values = has_backend_values || has_values;
    }
#endif

#if defined(DM_PLATFORM_LINUX)
    if (!has_backend_values)
    {
        has_backend_values = CollectLinuxDrmGpuInfo(L) || has_backend_values;
        has_values = has_backend_values || has_values;
    }
#endif

#if defined(DM_PLATFORM_OSX)
    if (family == dmGraphics::ADAPTER_FAMILY_METAL)
    {
        has_backend_values = SentinelPushMacOSMetalGpuInfo(L, true) || has_backend_values;
        has_values = has_backend_values || has_values;
    }
    else if (family == dmGraphics::ADAPTER_FAMILY_VULKAN && !has_backend_values)
    {
        has_backend_values = SentinelPushMacOSMetalGpuInfo(L, false) || has_backend_values;
        has_values = has_backend_values || has_values;
    }
#endif

    if (!has_values)
    {
        lua_pop(L, 1);
        lua_pushnil(L);
    }

    return 1;
}

static const luaL_reg SentinelNative_methods[] =
{
    {"get_gpu_info", GetGpuInfo},
    {0, 0}
};

static void LuaInit(lua_State* L)
{
    int top = lua_gettop(L);
    luaL_register(L, MODULE_NAME, SentinelNative_methods);
    lua_pop(L, 1);
    assert(top == lua_gettop(L));
}

static dmExtension::Result AppInitializeSentinel(dmExtension::AppParams* params)
{
    return dmExtension::RESULT_OK;
}

static dmExtension::Result InitializeSentinel(dmExtension::Params* params)
{
    LuaInit(params->m_L);
    return dmExtension::RESULT_OK;
}

static dmExtension::Result AppFinalizeSentinel(dmExtension::AppParams* params)
{
    return dmExtension::RESULT_OK;
}

static dmExtension::Result FinalizeSentinel(dmExtension::Params* params)
{
    return dmExtension::RESULT_OK;
}

DM_DECLARE_EXTENSION(Sentinel, LIB_NAME, AppInitializeSentinel, AppFinalizeSentinel, InitializeSentinel, NULL, NULL, FinalizeSentinel)
