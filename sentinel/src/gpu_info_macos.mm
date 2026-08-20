#include <dmsdk/sdk.h>

#include <stdio.h>

#if defined(DM_PLATFORM_OSX)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

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

static bool Contains(NSString* value, NSString* needle)
{
    return value && needle && [value rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static const char* InferVendorName(NSString* name)
{
    if (Contains(name, @"AMD") || Contains(name, @"Radeon"))
    {
        return "AMD";
    }
    if (Contains(name, @"Intel"))
    {
        return "Intel";
    }
    if (Contains(name, @"NVIDIA") || Contains(name, @"GeForce"))
    {
        return "NVIDIA";
    }
    if (Contains(name, @"Apple"))
    {
        return "Apple";
    }

    return 0;
}

extern "C" bool SentinelPushMacOSMetalGpuInfo(lua_State* L, bool push_api_fields)
{
    @autoreleasepool
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device)
        {
            return false;
        }

        NSString* name = [device name];
        const char* name_utf8 = name ? [name UTF8String] : 0;

        if (push_api_fields)
        {
            PushStringField(L, "api_type", "Metal");
            PushStringField(L, "version", "Metal");
        }
        PushStringField(L, "name", name_utf8);
        PushStringField(L, "renderer", name_utf8);
        PushStringField(L, "vendor_name", InferVendorName(name));

        if ([device respondsToSelector:@selector(registryID)])
        {
            uint64_t registry_id = [device registryID];
            if (registry_id != 0)
            {
                char buffer[32];
                snprintf(buffer, sizeof(buffer), "0x%llx", (unsigned long long) registry_id);
                PushStringField(L, "id", buffer);
            }
        }

        if ([device respondsToSelector:@selector(recommendedMaxWorkingSetSize)])
        {
            uint64_t memory_size = [device recommendedMaxWorkingSetSize];
            PushIntegerField(L, "memory_size", (lua_Integer) (memory_size / (1024ULL * 1024ULL)));
        }

        return true;
    }
}
#else
extern "C" bool SentinelPushMacOSMetalGpuInfo(lua_State* L, bool push_api_fields)
{
    return false;
}
#endif
