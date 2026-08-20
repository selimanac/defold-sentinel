#if defined(DM_PLATFORM_WINDOWS) && !defined(WIN32_LEAN_AND_MEAN)
#define WIN32_LEAN_AND_MEAN
#endif

#define LIB_NAME "Sentinel"
#define MODULE_NAME "sentinel_native"

#include <dmsdk/sdk.h>
#include <dmsdk/graphics/graphics.h>

#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#if defined(DM_PLATFORM_WINDOWS)
#include <windows.h>
#include <GL/gl.h>
#include <dxgi.h>
#elif defined(DM_PLATFORM_LINUX)
#include <dirent.h>
#include <stdio.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <GL/gl.h>
#elif defined(DM_PLATFORM_OSX)
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <OpenGL/gl3.h>
#include <sys/sysctl.h>
#endif

#if defined(DM_PLATFORM_OSX)
extern "C" bool SentinelPushMacOSMetalGpuInfo(lua_State* L, bool push_api_fields);
#endif

#if defined(DM_PLATFORM_WINDOWS) || defined(DM_PLATFORM_LINUX)
// The system <GL/gl.h> on Windows and Linux only declares OpenGL 1.1, so this
// GL 2.0 token (used by glGetString below) isn't defined without pulling in glext.h.
#ifndef GL_SHADING_LANGUAGE_VERSION
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#endif
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

static void PushNumberField(lua_State* L, const char* key, double value)
{
    if (value > 0)
    {
        lua_pushnumber(L, value);
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

    const char* renderer                 = (const char*)glGetString(GL_RENDERER);
    const char* version                  = (const char*)glGetString(GL_VERSION);
    const char* vendor                   = (const char*)glGetString(GL_VENDOR);
    const char* shading_language_version = (const char*)glGetString(GL_SHADING_LANGUAGE_VERSION);

    PushStringField(L, "name", renderer);
    PushStringField(L, "renderer", renderer);
    PushStringField(L, "version", version);
    PushStringField(L, "vendor_name", vendor);
    PushStringField(L, "graphics_shader_level", shading_language_version);

    return renderer || version || vendor || shading_language_version;
}
#endif

#if defined(DM_PLATFORM_OSX)
static bool ReadSysctlString(const char* name, char* buffer, size_t buffer_size)
{
    if (!buffer || buffer_size == 0)
    {
        return false;
    }

    size_t size = buffer_size;
    if (sysctlbyname(name, buffer, &size, 0, 0) != 0 || size == 0)
    {
        buffer[0] = '\0';
        return false;
    }

    buffer[buffer_size - 1] = '\0';
    return buffer[0] != '\0';
}

static bool ReadSysctlInt(const char* name, int* value)
{
    size_t size = sizeof(*value);
    return value && sysctlbyname(name, value, &size, 0, 0) == 0;
}

static bool ReadSysctlUInt64(const char* name, uint64_t* value)
{
    size_t size = sizeof(*value);
    return value && sysctlbyname(name, value, &size, 0, 0) == 0;
}

static uint64_t GetMacOSFreeMemoryBytes()
{
    mach_port_t host = mach_host_self();
    vm_size_t page_size = 0;
    if (host_page_size(host, &page_size) != KERN_SUCCESS || page_size == 0)
    {
        mach_port_deallocate(mach_task_self(), host);
        return 0;
    }

    vm_statistics64_data_t vm_stat;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm_stat, &count) != KERN_SUCCESS)
    {
        mach_port_deallocate(mach_task_self(), host);
        return 0;
    }

    uint64_t pages = (uint64_t)vm_stat.free_count + (uint64_t)vm_stat.inactive_count + (uint64_t)vm_stat.speculative_count;
    uint64_t bytes = pages * (uint64_t)page_size;
    mach_port_deallocate(mach_task_self(), host);
    return bytes;
}

static bool CollectMacOSDeviceInfo(lua_State* L)
{
    bool has_values = false;

    char arch[128];
    if (ReadSysctlString("hw.machine", arch, sizeof(arch)))
    {
        PushStringField(L, "arch", arch);
        has_values = true;
    }

    char cpu_description[256];
    if (ReadSysctlString("machdep.cpu.brand_string", cpu_description, sizeof(cpu_description)) ||
        ReadSysctlString("hw.model", cpu_description, sizeof(cpu_description)))
    {
        PushStringField(L, "cpu_description", cpu_description);
        has_values = true;
    }

    int logical_cpu = 0;
    if (ReadSysctlInt("hw.logicalcpu", &logical_cpu))
    {
        PushIntegerField(L, "processor_count", logical_cpu);
        has_values = true;
    }

    uint64_t memory_size = 0;
    if (ReadSysctlUInt64("hw.memsize", &memory_size))
    {
        PushNumberField(L, "memory_size", (double)memory_size);
        has_values = true;
    }

    uint64_t cpu_frequency = 0;
    if (ReadSysctlUInt64("hw.cpufrequency", &cpu_frequency) && cpu_frequency > 0)
    {
        PushNumberField(L, "processor_frequency", (double)(cpu_frequency / 1000000ULL));
        has_values = true;
    }

    uint64_t free_memory = GetMacOSFreeMemoryBytes();
    if (free_memory > 0)
    {
        PushNumberField(L, "free_memory", (double)free_memory);
        has_values = true;
    }

    return has_values;
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
    HRESULT hr             = CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&factory);
    if (FAILED(hr) || !factory)
    {
        return false;
    }

    bool has_values = false;
    for (UINT i = 0;; ++i)
    {
        IDXGIAdapter1* adapter = 0;
        hr                     = factory->EnumAdapters1(i, &adapter);
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
            PushIntegerField(L, "memory_size", (lua_Integer)(desc.DedicatedVideoMemory / (1024ULL * 1024ULL)));
            has_values = true;
            adapter->Release();
            break;
        }

        adapter->Release();
    }

    factory->Release();
    return has_values;
}

static const char* WindowsProcessorArchitectureToString(WORD architecture)
{
    switch (architecture)
    {
        case PROCESSOR_ARCHITECTURE_AMD64:
            return "x86_64";
        case PROCESSOR_ARCHITECTURE_ARM:
            return "arm";
        case PROCESSOR_ARCHITECTURE_ARM64:
            return "arm64";
        case PROCESSOR_ARCHITECTURE_INTEL:
            return "x86";
        case PROCESSOR_ARCHITECTURE_IA64:
            return "ia64";
        default:
            return 0;
    }
}

static bool ReadWindowsRegistryString(HKEY key, const char* name, char* buffer, DWORD buffer_size)
{
    DWORD type = 0;
    DWORD size = buffer_size;
    LONG result = RegQueryValueExA(key, name, 0, &type, (LPBYTE)buffer, &size);
    if (result != ERROR_SUCCESS || type != REG_SZ || size == 0)
    {
        if (buffer_size > 0)
        {
            buffer[0] = '\0';
        }
        return false;
    }

    buffer[buffer_size - 1] = '\0';
    return buffer[0] != '\0';
}

static bool ReadWindowsRegistryDword(HKEY key, const char* name, DWORD* value)
{
    DWORD type = 0;
    DWORD size = sizeof(*value);
    return value && RegQueryValueExA(key, name, 0, &type, (LPBYTE)value, &size) == ERROR_SUCCESS && type == REG_DWORD;
}

static bool CollectWindowsDeviceInfo(lua_State* L)
{
    bool has_values = false;

    MEMORYSTATUSEX memory_status;
    memset(&memory_status, 0, sizeof(memory_status));
    memory_status.dwLength = sizeof(memory_status);
    if (GlobalMemoryStatusEx(&memory_status))
    {
        PushNumberField(L, "memory_size", (double)memory_status.ullTotalPhys);
        PushNumberField(L, "free_memory", (double)memory_status.ullAvailPhys);
        has_values = true;
    }

    SYSTEM_INFO system_info;
    memset(&system_info, 0, sizeof(system_info));
    GetNativeSystemInfo(&system_info);
    PushStringField(L, "arch", WindowsProcessorArchitectureToString(system_info.wProcessorArchitecture));
    PushIntegerField(L, "processor_count", (lua_Integer)system_info.dwNumberOfProcessors);
    has_values = has_values || system_info.dwNumberOfProcessors > 0 || WindowsProcessorArchitectureToString(system_info.wProcessorArchitecture) != 0;

    HKEY cpu_key = 0;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", 0, KEY_QUERY_VALUE, &cpu_key) == ERROR_SUCCESS)
    {
        char cpu_description[256];
        if (ReadWindowsRegistryString(cpu_key, "ProcessorNameString", cpu_description, sizeof(cpu_description)))
        {
            PushStringField(L, "cpu_description", cpu_description);
            has_values = true;
        }

        DWORD mhz = 0;
        if (ReadWindowsRegistryDword(cpu_key, "~MHz", &mhz))
        {
            PushIntegerField(L, "processor_frequency", (lua_Integer)mhz);
            has_values = true;
        }

        RegCloseKey(cpu_key);
    }

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

    bool has_values      = false;
    struct dirent* entry = 0;
    while ((entry = readdir(dir)) != 0)
    {
        if (strncmp(entry->d_name, "card", 4) != 0)
        {
            continue;
        }

        // Skip connector entries such as "card0-DP-1"/"card0-HDMI-A-1" — only
        // match true "cardN" device directories (digits-only suffix).
        const char* suffix = entry->d_name + 4;
        if (suffix[0] == '\0')
        {
            continue;
        }
        bool is_card_device = true;
        for (const char* c = suffix; *c != '\0'; ++c)
        {
            if (*c < '0' || *c > '9')
            {
                is_card_device = false;
                break;
            }
        }
        if (!is_card_device)
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

static char* TrimLeft(char* value)
{
    while (value && (*value == ' ' || *value == '\t'))
    {
        ++value;
    }
    return value;
}

static void TrimRight(char* value)
{
    if (!value)
    {
        return;
    }

    size_t length = strlen(value);
    while (length > 0 && (value[length - 1] == '\n' || value[length - 1] == '\r' || value[length - 1] == ' ' || value[length - 1] == '\t'))
    {
        value[--length] = '\0';
    }
}

static bool ParseProcCpuInfo(lua_State* L)
{
    FILE* file = fopen("/proc/cpuinfo", "r");
    if (!file)
    {
        return false;
    }

    bool has_values = false;
    bool has_description = false;
    bool has_frequency = false;
    char line[512];
    while (fgets(line, sizeof(line), file) != 0)
    {
        char* separator = strchr(line, ':');
        if (!separator)
        {
            continue;
        }

        *separator = '\0';
        char* key = TrimLeft(line);
        TrimRight(key);
        char* value = TrimLeft(separator + 1);
        TrimRight(value);

        if (!has_description && (strcmp(key, "model name") == 0 || strcmp(key, "Hardware") == 0))
        {
            PushStringField(L, "cpu_description", value);
            has_description = value && value[0] != '\0';
            has_values = has_values || has_description;
        }
        else if (!has_frequency && strcmp(key, "cpu MHz") == 0)
        {
            double frequency = strtod(value, 0);
            PushNumberField(L, "processor_frequency", frequency);
            has_frequency = frequency > 0;
            has_values = has_values || has_frequency;
        }

        if (has_description && has_frequency)
        {
            break;
        }
    }

    fclose(file);
    return has_values;
}

static bool CollectLinuxDeviceInfo(lua_State* L)
{
    bool has_values = false;

    struct utsname uts;
    if (uname(&uts) == 0)
    {
        PushStringField(L, "arch", uts.machine);
        has_values = true;
    }

    long page_size = sysconf(_SC_PAGESIZE);
    long physical_pages = sysconf(_SC_PHYS_PAGES);
    long available_pages = sysconf(_SC_AVPHYS_PAGES);
    if (page_size > 0 && physical_pages > 0)
    {
        PushNumberField(L, "memory_size", (double)((uint64_t)page_size * (uint64_t)physical_pages));
        has_values = true;
    }
    if (page_size > 0 && available_pages > 0)
    {
        PushNumberField(L, "free_memory", (double)((uint64_t)page_size * (uint64_t)available_pages));
        has_values = true;
    }

    long processor_count = sysconf(_SC_NPROCESSORS_ONLN);
    if (processor_count > 0)
    {
        PushIntegerField(L, "processor_count", (lua_Integer)processor_count);
        has_values = true;
    }

    has_values = ParseProcCpuInfo(L) || has_values;
    return has_values;
}
#endif

static int GetGpuInfo(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);

    lua_newtable(L);

    bool has_values                  = false;
    bool has_backend_values          = false;
    dmGraphics::AdapterFamily family = dmGraphics::GetInstalledAdapterFamily();
    const char* api_type             = AdapterFamilyToApiType(family);
    if (api_type)
    {
        PushStringField(L, "api_type", api_type);
        has_values = true;
    }

#if defined(DM_PLATFORM_WINDOWS) || defined(DM_PLATFORM_LINUX) || defined(DM_PLATFORM_OSX)
    if (family == dmGraphics::ADAPTER_FAMILY_OPENGL || family == dmGraphics::ADAPTER_FAMILY_OPENGLES)
    {
        has_backend_values = CollectOpenGLGpuInfo(L, family) || has_backend_values;
        has_values         = has_backend_values || has_values;
    }
#endif

#if defined(DM_PLATFORM_WINDOWS)
    if (family == dmGraphics::ADAPTER_FAMILY_DIRECTX || !has_backend_values)
    {
        has_backend_values = CollectWindowsDxgiGpuInfo(L, family == dmGraphics::ADAPTER_FAMILY_DIRECTX) || has_backend_values;
        has_values         = has_backend_values || has_values;
    }
#endif

#if defined(DM_PLATFORM_LINUX)
    if (!has_backend_values)
    {
        has_backend_values = CollectLinuxDrmGpuInfo(L) || has_backend_values;
        has_values         = has_backend_values || has_values;
    }
#endif

#if defined(DM_PLATFORM_OSX)
    if (family == dmGraphics::ADAPTER_FAMILY_METAL)
    {
        has_backend_values = SentinelPushMacOSMetalGpuInfo(L, true) || has_backend_values;
        has_values         = has_backend_values || has_values;
    }
    else if (family == dmGraphics::ADAPTER_FAMILY_VULKAN && !has_backend_values)
    {
        has_backend_values = SentinelPushMacOSMetalGpuInfo(L, false) || has_backend_values;
        has_values         = has_backend_values || has_values;
    }
#endif

    if (!has_values)
    {
        lua_pop(L, 1);
        lua_pushnil(L);
    }

    return 1;
}

static int GetDeviceInfo(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);

    lua_newtable(L);

    bool has_values = false;

#if defined(DM_PLATFORM_OSX)
    has_values = CollectMacOSDeviceInfo(L) || has_values;
#elif defined(DM_PLATFORM_WINDOWS)
    has_values = CollectWindowsDeviceInfo(L) || has_values;
#elif defined(DM_PLATFORM_LINUX)
    has_values = CollectLinuxDeviceInfo(L) || has_values;
#endif

    if (!has_values)
    {
        lua_pop(L, 1);
        lua_pushnil(L);
    }

    return 1;
}

static const luaL_reg SentinelNative_methods[] = {
    { "get_gpu_info", GetGpuInfo },
    { "get_device_info", GetDeviceInfo },
    { 0, 0 }
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
