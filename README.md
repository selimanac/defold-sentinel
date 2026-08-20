[![Sentinel Cover](cover.jpg)](https://github.com/indiesoftby/defold-sentinel)

# Sentinel: Sentry.io SDK for Defold

*This is an open-source project. It is not affiliated with Sentry.io.*

[Sentry.io](https://sentry.io/) is an error tracking system. It can track errors and performance issues in any language, framework, and library.

This Defold extension, Sentinel, implements **error tracking** for your **Lua code**. It can also report previous Defold native crash dumps through Defold's `crash` API when that API is available, and it can inject the JavaScript SDK to track HTML5 errors if you need that.

Sentry.io is a paid system, but it has a free plan for developers to track up to 5,000 errors per month. To the point, it was enough to track down all Lua errors in [Puffy Cat](https://poki.com/en/g/puffy-cat) during a test period and release a pretty polished game.

## Supported Platforms

| Platform | Status |
| -------- | ------ |
| Defold Lua errors (all platforms) | Supported ✅ |
| Browser (HTML5) | Loads JavaScript SDK to track non-Lua errors ☑️ |
| Defold native crash dumps | Reports previous crash dumps through Defold's `crash` API when available |
| GPU context | Adds portable Defold adapter data and best-effort desktop native GPU fields |
| Device context | Adds best-effort desktop CPU/RAM fields to `contexts.device` |
| Native minidump/Crashpad-style capture and full symbolication | Not Implemented ❌ |

## Installation & Usage

You can use Sentinel in your own project by adding this project as a [Defold library dependency](http://www.defold.com/manuals/libraries/).

Open your `game.project` file and in the dependencies field under project add the ZIP file of a [specific release](https://github.com/indiesoftby/defold-sentinel/releases).

### Init

```lua
local sentry = require("sentinel.sentry")

function init(self)
    sentry.init({
        -- The DSN tells the SDK where to send the events to.
        -- Example of the DSN url: https://a09cb15ea1224b7db88ff3681c0d574f@o43904.ingest.sentry.io/5395416
        dsn = sys.get_config_string("sentinel.sentry_dsn"),

        debug = sys.get_config_boolean("sentinel.sentry_debug", false),
        dry_run = sys.get_config_boolean("sentinel.sentry_dry_run", false),
        environment = sys.get_config_string("sentinel.sentry_environment", "production"),
        send_timeout = sys.get_config_number("sentinel.sentry_send_timeout", 30),

        -- Installs sys.set_error_handler() and captures uncaught Lua errors.
        set_error_handler = true,

        -- Loads and reports the previous Defold native crash dump on startup.
        load_previous_crash = sys.get_config_boolean("sentinel.sentry_load_previous_crash", true),

        -- Adds contexts.gpu and extra.defold_graphics to every event.
        collect_gpu_info = sys.get_config_boolean("sentinel.sentry_collect_gpu_info", true),
        gpu_extensions_limit = sys.get_config_number("sentinel.sentry_gpu_extensions_limit", 128),

        -- Adds contexts.device CPU/RAM data to every event.
        collect_device_info = sys.get_config_boolean("sentinel.sentry_collect_device_info", true),

        -- Tags and extra data are optional
        tags = {
            ["example_tag"] = "Example Tag Data",
        },
        extra = {
            ["example_extra"] = "Example Extra Data",
        },

        -- Optional. If omitted, Sentinel uses project.title@project.version.
        release = sys.get_config_string("sentinel.sentry_release", ""),

        -- Outgoing Sentry requests are compressed with Defold zlib/deflate by default.
        -- Set this to false to send plain JSON instead.
        compress_requests = true
    })
end
```

### Breadcrumbs, Capturing Messages

```lua
--- Add breadcrumbs, add tags, extras, and capture messages:
sentry.add_breadcrumb(
    {
        category = "log",
        message = "Test breadcrumb message"
    })

sentry.set_tag("my_info", "Amount of gold")
sentry.set_extra("frametime", 100)
sentry.set_extra("cheater", true)

sentry.capture_message(
    {
        message = "Test message",
        level = "info",
        -- Sentinel's Sentry client merges globally defined tags/extra with this data,
        -- i.e. you can add tags and extras for different kinds of messages and exceptions.
        extra = {
            example_extra_2 = "Hello!"
        }
    })
```

![Example Sentry Issue](example_sentry_issue.png)

### Runtime State And Crash APIs

Sentinel keeps a small runtime state table for debugging and integrations:

```lua
if sentry.is_initialized() then
    local state = sentry.get_state()
    print(state.last_status, state.last_event_id, state.last_error)
end
```

`sentry.get_state()` returns a copy of:

```lua
{
    initialized = true,
    previous_crash_checked = true,
    previous_crash_found = false,
    previous_crash_reported = false,
    last_status = "Sentry initialized",
    last_status_success = true,
    last_event_id = "event-id",
    last_error = nil
}
```

For native crash context, you can write Defold crash user fields by numeric index before or after `sentry.init()`:

```lua
sentry.set_crash_user_field(0, "my-game@1.0.0")
sentry.set_crash_user_field(1, "production")
sentry.set_crash_user_field(4, "entered_boss_room")
```

After `sentry.init()`, you can also configure names for those fields:

```lua
sentry.init({
    dsn = "...",
    crash_user_field_names = {
        release = 0,
        environment = 1,
        last_event = 4,
        build_id = 5
    }
})

sentry.set_crash_user_field("last_event", "opened_inventory")
```

Desktop/debug crash helpers:

```lua
-- Writes a Defold crash dump for local testing. Restart the app to report it.
local ok, err = sentry.write_crash_dump()

-- Manually report the previous crash dump, if one exists and was not already checked.
local ok, err = sentry.report_previous_crash({
    tags = {
        source = "manual_debug"
    },
    callback = function(id, err)
        print(id, err)
    end
})
```

All `crash.*` calls are guarded. On platforms where Defold's `crash` module is missing or unavailable, these APIs return `false, err` instead of throwing.

### Lua Error Reporting

When `set_error_handler = true`, Sentinel installs `sys.set_error_handler()` and captures uncaught Lua errors.

Lua errors are sent as Sentry exception events with parsed Lua stack frames. Sentinel also sets a custom fingerprint from release, error type, file, function, and line so errors from different Lua locations do not group only by the message title.

Errors captured by the Defold error handler are marked with:

```lua
mechanism = {
    type = "lua",
    handled = false
}
```

The Sentry level remains `"error"` unless you explicitly pass `fatal = true` to `sentry.capture_exception()`.

### Previous Native Crash Reporting

When `load_previous_crash = true`, `sentry.init()` calls `sentry.report_previous_crash()` once during startup.

Previous Defold native crash reports are sent as fatal exception events with:

- message: `Previous Defold native crash`
- tag `kind = "defold_crash"`
- tag `platform = sys.get_sys_info().system_name`
- the same cached device and GPU context used by normal Lua events
- native stack frames generated from `crash.get_backtrace()`
- module-relative frame keys generated from `crash.get_modules()`
- a native crash fingerprint based on project, release, environment, signal, and top native frames
- extras for `signum`, `extra_data`, `backtrace_json`, `backtrace_count`, `modules_json`, `module_count`, `sys_fields_json`, and `user_fields_json`

This improves grouping for previous Defold native crash reports. It is not full native symbolication: addresses stored only in extras are not enough for dSYM/PDB symbolication, and Defold's Lua `crash` API does not provide complete Sentry debug-image metadata here.

### GPU Context

By default, Sentinel collects GPU information once during `sentry.init()` and attaches it to every event. Portable data comes from Defold's `graphics.get_adapter_info()`. Desktop builds also expose `sentinel_native.get_gpu_info()` to collect best-effort active adapter strings and IDs from the native backend.

Events include normalized Sentry GPU data in `contexts.gpu`, including `name`, `vendor_name`, `vendor_id`, `id`, `device_id`, `version`, `driver_version`, `api_type`, `memory_size`, `max_texture_size`, `supports_compute_shaders`, and `supports_draw_call_instancing` when available.

Verbose Defold adapter data is stored in `extra.defold_graphics`: `family`, `version_major`, `version_minor`, `limits`, `features`, `extensions`, `extensions_count`, and `extensions_truncated`. `gpu_extensions_limit` defaults to `128` to keep payloads bounded. Set `collect_gpu_info = false` to disable this collection.

Sentinel only adds low-cardinality GPU tags: `gpu.api_type`, `gpu.vendor_name`, and `gpu.vendor_id`. Full renderer names are not tagged unless your app adds its own tag.

### Device Context

By default, Sentinel collects best-effort desktop CPU/RAM information through `sentinel_native.get_device_info()` during `sentry.init()` and attaches it to every event as `contexts.device`.

Device fields follow Sentry's device context schema when available: `arch`, `memory_size`, `free_memory`, `processor_count`, `cpu_description`, and `processor_frequency`. `memory_size` and `free_memory` are bytes. Static fields are cached during init; `free_memory` is refreshed when each event is created, so previous native-crash reports contain current startup memory rather than historical crash-time memory.

Sentinel does not add CPU/RAM tags. Set `collect_device_info = false` to disable this collection.

### Configuration Options

`sentry.init()` accepts:

```lua
{
    dsn = "YOUR_DSN_URL",
    debug = false,
    dry_run = false,
    compress_requests = true,
    collect_gpu_info = true,
    gpu_extensions_limit = 128,
    collect_device_info = true,
    gameanalytics = false,
    send_timeout = 30,
    set_error_handler = true,
    load_previous_crash = true,
    release = "project-title@project-version",
    dist = "optional-dist",
    environment = "production",
    user = {},
    tags = {},
    extra = {},
    crash_extra_text_limit = 8192,
    crash_user_field_names = {},
    previous_crash_event = {}
}
```

`release` is optional. If it is missing or empty, Sentinel defaults to:

```lua
sys.get_config_string("project.title") .. "@" .. sys.get_config_string("project.version")
```

`previous_crash_event` can override or extend the generated previous-crash event:

```lua
sentry.init({
    dsn = "...",
    previous_crash_event = {
        tags = {
            channel = "steam"
        },
        extra = {
            startup_phase = "boot"
        },
        callback = function(id, err)
            print("Previous crash:", id, err)
        end
    }
})
```

Capture callbacks are protected with `pcall()`, so a callback error will not break the HTTP response path. Successful sends update `get_state().last_event_id`; request/decode/status failures update `get_state().last_error`.

### The `game.project` Settings:

```ini
[project]
title = my_game
version = 1.0.0

[sentinel]
sentry_dsn = YOUR_LUA_OR_DESKTOP_DSN_URL_FROM_SENTRY_IO
sentry_dsn_html5 = YOUR_HTML5_DSN_URL_FROM_SENTRY_IO
sentry_environment = production
sentry_enabled = 1
sentry_debug = 0
sentry_dry_run = 0
sentry_send_timeout = 10
sentry_load_previous_crash = 1
sentry_collect_gpu_info = 1
sentry_gpu_extensions_limit = 128
sentry_collect_device_info = 1

# Optional overrides
# sentry_release = my_game@1.0.0
# sentry_build_id = steam-1234
```

`sentry.lua` itself only requires a DSN passed to `sentry.init()`. The `sentinel.*` keys are a convenient project-level convention used by the example test script and by your own integration code.

Setting the `sentinel.sentry_dsn_html5` option initializes Sentry JavaScript SDK in the HTML5 template ([take a look at how it's done](https://github.com/indiesoftby/defold-sentinel/blob/main/sentinel/manifests/web/engine_template.html#L3)). The Lua SDK uses `sentinel.sentry_dsn` when your code passes it to `sentry.init()`.

`sentinel.sentry_release` is optional. If it is omitted, Sentinel uses `project.title@project.version`.

Sentinel compresses Lua `http.request` payloads with Defold's `zlib.deflate()` by default and sends them with
`Content-Encoding: deflate`. Set `compress_requests = false` in `sentry.init()` if you need to disable request
compression.

Sentinel collects GPU context by default. Set `collect_gpu_info = false` in `sentry.init()` to disable it, or lower
`gpu_extensions_limit` if you want smaller event payloads.

Sentinel collects desktop CPU/RAM device context by default. Set `collect_device_info = false` in `sentry.init()` to
disable it.

### Desktop Test Script

The example project includes `/example/test.script` and attaches it in `/example/main.collection` for local desktop validation. It is a debug harness, not a required SDK helper.

It reads the `sentinel.*` keys from `game.project`, initializes `sentinel.sentry`, and exposes these inputs:

| Input | Action |
| ----- | ------ |
| `M` | send a test message |
| `E` | trigger a delayed Lua error |
| `D` | write a Defold crash dump; restart the app to report it |
| `R` | manually report the previous crash dump |
| `S` | print `sentry.get_state()` |
| touch/click | send a test message |

Before releasing the example or using the library in a real game, replace test DSNs and either remove this script or point the collection back to your production script.

### GameAnalytics Compatibility

Only one [`sys.set_error_handler`](https://defold.com/ref/sys/#sys.set_error_handler:error_handler) callback can be set. To track Lua errors both in GameAnalytics and Sentinel, use the option, i.e. Sentinel will send captured errors to both, Sentry and GameAnalytics:

```lua
sentry.init({
    --
    -- ... your config ...
    --
    gameanalytics = true
})
```

Plus, look into the `sentinel/sentry.lua` module to find all available configuration options!

## Credits

Artsiom Trubchyk ([@aglitchman](https://github.com/aglitchman)) is the current Sentinel owner within Indiesoft and is responsible for the open source repository.

This project uses the source code of [rxi's JSON](https://github.com/rxi/json.lua). 

Queen's Guard image is by [Chanut is Industries](https://thenounproject.com/chanut-is/).

### License

MIT license.
