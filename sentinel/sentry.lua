--
-- Sentinel: Sentry.io for Defold.
-- *******************************
--
-- The latest version available at: https://github.com/indiesoftby/defold-sentinel
-- SDK Development Documentation: https://develop.sentry.dev/sdk/overview/
--

local M                              = {}

local LOG_PREFIX                     = "SENTINEL: "
local LOGGER_NAME                    = "sentinel"
local VERSION                        = "1.3.2"
local USER_AGENT                     = "sentinel-sentry/" .. VERSION

local APP_PATH                       = sys.get_application_path()
local ENGINE_INFO                    = sys.get_engine_info()
local SYS_INFO                       = sys.get_sys_info({ ignore_secure = true })

local DEFAULT_CRASH_EXTRA_TEXT_LIMIT = 8192
local DEFAULT_CRASH_USER_FIELD_SIZE  = 255
local DEFAULT_CRASH_USER_FIELD_MAX   = 32
local DEFAULT_GPU_EXTENSIONS_LIMIT   = 128
local CRASH_FINGERPRINT_FRAME_LIMIT  = 6

local state                          = {
    initialized             = false,
    previous_crash_checked  = false,
    previous_crash_found    = false,
    previous_crash_reported = false,
    last_status             = "Not initialized",
    last_status_success     = false,
    last_event_id           = nil,
    last_error              = nil
}

--- Generates a unique event ID suitable for use in Sentry.
-- This function creates a 32-character hexadecimal string based on the current time and random numbers.
-- @treturn string A 32-character hexadecimal string representing the event ID.
local function generate_event_id()
    local h = hash_to_hex(hash(tostring(socket.gettime()) .. string.format("%07x", math.random(0, 0xfffffff))))
    while string.len(h) < 32 do
        h = h .. hash_to_hex(hash(string.format("%07x", math.random(0, 0xfffffff))))
    end
    return string.sub(h, 1, 32)
end

--- Logs a message via `print`. If running in HTML5 and not in debug mode, it uses `console.log`.
-- @tparam any v The value to be logged.
local function log_print(v)
    if html5 and not ENGINE_INFO.is_debug then
        html5.run("console.log(" .. json.encode(LOG_PREFIX .. tostring(v)) .. ")")
    else
        print(LOG_PREFIX .. tostring(v))
    end
end

local function set_status(text, success)
    state.last_status = text
    state.last_status_success = success
    if success then
        state.last_error = nil
    else
        state.last_error = text
    end
end

local function safe_call(fn, ...)
    if type(fn) ~= "function" then
        return nil, "function unavailable"
    end

    local ok, value = pcall(fn, ...)
    if ok then
        return value, nil
    end

    return nil, value
end

local function trim_text(value, limit)
    if value == nil then
        return nil
    end

    local text = tostring(value)
    if string.len(text) <= limit then
        return text
    end

    return string.sub(text, 1, limit) .. "...(truncated)"
end

local function get_crash_extra_text_limit()
    if type(M.config) == "table" and type(M.config.crash_extra_text_limit) == "number" then
        return M.config.crash_extra_text_limit
    end

    return DEFAULT_CRASH_EXTRA_TEXT_LIMIT
end

local function get_crash_user_field_size()
    if type(crash) == "table" and type(crash.USERFIELD_SIZE) == "number" then
        return crash.USERFIELD_SIZE
    end

    return DEFAULT_CRASH_USER_FIELD_SIZE
end

local function get_crash_user_field_max()
    if type(crash) == "table" and type(crash.USERFIELD_MAX) == "number" then
        return crash.USERFIELD_MAX
    end

    return DEFAULT_CRASH_USER_FIELD_MAX
end

local function make_default_release()
    local title = sys.get_config_string("project.title", "")
    local version = sys.get_config_string("project.version", "")

    if title ~= "" and version ~= "" then
        return title .. "@" .. version
    end

    if title ~= "" then
        return title
    end

    if version ~= "" then
        return version
    end

    return nil
end

local function encode_extra(value)
    local ok, encoded = pcall(json.encode, value)
    if ok then
        return trim_text(encoded, get_crash_extra_text_limit())
    end

    return trim_text(encoded, get_crash_extra_text_limit())
end

local function wrap_capture_callback(callback)
    return function(id, err)
        if err then
            set_status("Sentry send failed: " .. tostring(err), false)
        else
            state.last_event_id = id
            set_status("Sentry event sent: " .. tostring(id), true)
        end

        if callback then
            local ok, callback_err = pcall(callback, id, err)
            if not ok then
                if type(M.config) == "table" and M.config.debug then
                    log_print("Capture callback error " .. tostring(callback_err))
                end
                set_status("Sentry callback failed: " .. tostring(callback_err), false)
            end
        end
    end
end

--- Merges key-value pairs from `src` table into `dest`. Copies non-empty string values from src to dest.
-- @tparam table dest The destination table to merge into.
-- @tparam table src The source table to merge from if not nil.
local function merge_kv(dest, src)
    if src then
        for k, v in pairs(src) do
            local s = tostring(v)
            if string.len(s) > 0 then
                dest[k] = s
            end
        end
    end
end

local function clone_event(event)
    local cloned = {}
    if not event then
        return cloned
    end

    for key, value in pairs(event) do
        cloned[key] = value
    end
    return cloned
end

local function copy_kv(dest, src)
    if type(src) ~= "table" then
        return
    end

    for key, value in pairs(src) do
        dest[key] = value
    end
end

local function apply_event_overrides(event, overrides)
    if type(overrides) ~= "table" then
        return
    end

    for key, value in pairs(overrides) do
        if key ~= "tags" and key ~= "extra" then
            event[key] = value
        end
    end

    event.tags = event.tags or {}
    event.extra = event.extra or {}
    copy_kv(event.tags, overrides.tags)
    copy_kv(event.extra, overrides.extra)
end

local function copy_table(value)
    if type(value) ~= "table" then
        return value
    end

    local copied = {}
    for key, item in pairs(value) do
        copied[key] = copy_table(item)
    end
    return copied
end

local function set_present_field(dest, key, value)
    if value == nil then
        return
    end
    if type(value) == "string" and value == "" then
        return
    end

    dest[key] = value
end

local function set_tag_field(tags, key, value)
    if value == nil then
        return
    end

    local text = tostring(value)
    if text == "" then
        return
    end

    tags[key] = text
end

local function get_gpu_extensions_limit()
    if type(M.config) == "table" and type(M.config.gpu_extensions_limit) == "number" then
        return math.max(0, math.floor(M.config.gpu_extensions_limit))
    end

    return DEFAULT_GPU_EXTENSIONS_LIMIT
end

local function adapter_family_to_api_type(family)
    if family == "opengl" then
        return "OpenGL"
    end
    if family == "opengles" then
        return "OpenGL ES"
    end
    if family == "vulkan" then
        return "Vulkan"
    end
    if family == "directx" then
        return "DirectX 12"
    end
    if family == "metal" then
        return "Metal"
    end
    if family == "webgpu" then
        return "WebGPU"
    end

    return nil
end

local function make_adapter_version(adapter_info)
    if type(adapter_info) ~= "table" then
        return nil
    end

    local major = adapter_info.version_major
    local minor = adapter_info.version_minor
    if type(major) == "number" and type(minor) == "number" then
        return tostring(major) .. "." .. tostring(minor)
    end

    return nil
end

local function has_feature(features, feature_id)
    if type(features) ~= "table" or feature_id == nil then
        return nil
    end

    for i = 1, #features do
        if features[i] == feature_id then
            return true
        end
    end

    return false
end

local function copy_defold_graphics_info(adapter_info)
    if type(adapter_info) ~= "table" then
        return nil
    end

    local info = {}
    set_present_field(info, "family", adapter_info.family)
    set_present_field(info, "version_major", adapter_info.version_major)
    set_present_field(info, "version_minor", adapter_info.version_minor)

    if type(adapter_info.limits) == "table" then
        info.limits = copy_table(adapter_info.limits)
    end
    if type(adapter_info.features) == "table" then
        info.features = copy_table(adapter_info.features)
    end

    local extensions = adapter_info.extensions
    local extensions_count = type(extensions) == "table" and #extensions or 0
    local limit = get_gpu_extensions_limit()
    info.extensions_count = extensions_count
    info.extensions_truncated = extensions_count > limit

    if extensions_count > 0 and limit > 0 then
        info.extensions = {}
        for i = 1, math.min(extensions_count, limit) do
            info.extensions[i] = extensions[i]
        end
    end

    return next(info) and info or nil
end

local function collect_defold_graphics_info()
    local graphics_module = rawget(_G, "graphics")
    if type(graphics_module) ~= "table" then
        return nil
    end

    local adapter_info = safe_call(graphics_module.get_adapter_info)
    if type(adapter_info) ~= "table" then
        return nil
    end

    return adapter_info
end

local function collect_native_gpu_info()
    local native_module = rawget(_G, "sentinel_native")
    if type(native_module) ~= "table" then
        return nil
    end

    local gpu_info = safe_call(native_module.get_gpu_info)
    if type(gpu_info) ~= "table" then
        return nil
    end

    return gpu_info
end

local function make_gpu_context(adapter_info, native_info)
    local context = {}
    native_info = type(native_info) == "table" and native_info or {}

    set_present_field(context, "name", native_info.name or native_info.renderer)
    set_present_field(context, "vendor_name", native_info.vendor_name)
    set_present_field(context, "vendor_id", native_info.vendor_id)
    set_present_field(context, "id", native_info.id or native_info.device_id)
    set_present_field(context, "device_id", native_info.device_id)
    set_present_field(context, "version", native_info.version or make_adapter_version(adapter_info))
    set_present_field(context, "driver_version", native_info.driver_version)
    set_present_field(context, "api_type", native_info.api_type or adapter_family_to_api_type(adapter_info and adapter_info.family))
    set_present_field(context, "memory_size", native_info.memory_size)
    set_present_field(context, "graphics_shader_level", native_info.graphics_shader_level)

    if type(adapter_info) == "table" then
        if type(adapter_info.limits) == "table" then
            set_present_field(context, "max_texture_size", adapter_info.limits.max_texture_size_2d)
        end

        local graphics_module = rawget(_G, "graphics")
        local features = adapter_info.features
        local compute_id = type(graphics_module) == "table" and graphics_module.CONTEXT_FEATURE_COMPUTE_SHADER or nil
        local instancing_id = type(graphics_module) == "table" and graphics_module.CONTEXT_FEATURE_INSTANCING or nil
        set_present_field(context, "supports_compute_shaders", has_feature(features, compute_id))
        set_present_field(context, "supports_draw_call_instancing", has_feature(features, instancing_id))
    end

    return next(context) and context or nil
end

local function collect_gpu_info()
    if type(M.config) == "table" and M.config.collect_gpu_info == false then
        return nil
    end

    local adapter_info = collect_defold_graphics_info()
    local native_info = collect_native_gpu_info()
    local gpu_context = make_gpu_context(adapter_info, native_info)
    local defold_graphics = copy_defold_graphics_info(adapter_info)

    if not gpu_context and not defold_graphics then
        return nil
    end

    return {
        context = gpu_context,
        defold_graphics = defold_graphics
    }
end

local function apply_gpu_info(event)
    local gpu_info = M.gpu_info
    if type(gpu_info) ~= "table" then
        return
    end

    if type(gpu_info.context) == "table" and next(gpu_info.context) ~= nil then
        event.contexts = event.contexts or {}
        event.contexts.gpu = copy_table(gpu_info.context)

        set_tag_field(event.tags, "gpu.api_type", gpu_info.context.api_type)
        set_tag_field(event.tags, "gpu.vendor_name", gpu_info.context.vendor_name)
        set_tag_field(event.tags, "gpu.vendor_id", gpu_info.context.vendor_id)
    end

    if type(gpu_info.defold_graphics) == "table" and next(gpu_info.defold_graphics) ~= nil then
        event.extra = event.extra or {}
        event.extra.defold_graphics = copy_table(gpu_info.defold_graphics)
    end
end

local function get_crash_sys_fields()
    if type(crash) ~= "table" then
        return {}
    end

    return {
        { key = "android_build_fingerprint", field = crash.SYSFIELD_ANDROID_BUILD_FINGERPRINT },
        { key = "device_language",           field = crash.SYSFIELD_DEVICE_LANGUAGE },
        { key = "device_model",              field = crash.SYSFIELD_DEVICE_MODEL },
        { key = "engine_hash",               field = crash.SYSFIELD_ENGINE_HASH },
        { key = "engine_version",            field = crash.SYSFIELD_ENGINE_VERSION },
        { key = "language",                  field = crash.SYSFIELD_LANGUAGE },
        { key = "manufacturer",              field = crash.SYSFIELD_MANUFACTURER },
        { key = "system_name",               field = crash.SYSFIELD_SYSTEM_NAME },
        { key = "system_version",            field = crash.SYSFIELD_SYSTEM_VERSION },
        { key = "territory",                 field = crash.SYSFIELD_TERRITORY }
    }
end

local function collect_crash_sys_fields(handle)
    local fields = {}
    local sys_fields = get_crash_sys_fields()

    for i = 1, #sys_fields do
        local item = sys_fields[i]
        local value = safe_call(crash.get_sys_field, handle, item.field)
        if value ~= nil and value ~= "" then
            fields[item.key] = value
        end
    end

    return fields
end

local function collect_crash_user_fields(handle)
    local fields = {}
    local max = get_crash_user_field_max()

    for i = 0, max - 1 do
        local value = safe_call(crash.get_user_field, handle, i)
        if value ~= nil and value ~= "" then
            fields[tostring(i)] = value
        end
    end

    return fields
end

local function count_items(value)
    if type(value) ~= "table" then
        return 0
    end

    return #value
end

local function normalize_hex_address(value)
    if type(value) == "number" then
        return string.format("0x%x", value)
    end

    if type(value) ~= "string" then
        return nil
    end

    local hex = string.match(value, "0[xX]([0-9a-fA-F]+)")
    if not hex then
        hex = string.match(value, "^%s*([0-9a-fA-F]+)%s*$")
    end

    if not hex then
        return nil
    end

    return "0x" .. string.lower(hex)
end

local function parse_hex_address(value)
    if type(value) == "number" then
        return value
    end

    local normalized = normalize_hex_address(value)
    if not normalized then
        return nil
    end

    return tonumber(string.sub(normalized, 3), 16)
end

local function get_module_name(module)
    if type(module) ~= "table" then
        return nil
    end

    return module.name or module.module or module.path or module.filename
end

local function get_module_address(module)
    if type(module) ~= "table" then
        return nil
    end

    return module.address or module.image_addr or module.base_address
end

local function find_crash_module(modules, address)
    if type(modules) ~= "table" or type(address) ~= "number" then
        return nil, nil
    end

    local best_module = nil
    local best_base = nil
    for i = 1, #modules do
        local base = parse_hex_address(get_module_address(modules[i]))
        if base and base <= address and (not best_base or base > best_base) then
            best_module = modules[i]
            best_base = base
        end
    end

    return best_module, best_base
end

local function make_native_frame_key(address, modules)
    local normalized = normalize_hex_address(address)
    if not normalized then
        return nil
    end

    local number_address = parse_hex_address(address)
    local module, module_base = find_crash_module(modules, number_address)
    local module_name = get_module_name(module)
    if module_name and module_base and number_address then
        local offset = number_address - module_base
        if offset >= 0 then
            return tostring(module_name) .. "+" .. string.format("0x%x", offset)
        end
    end

    return normalized
end

local function build_native_crash_frames(backtrace, modules)
    if type(backtrace) ~= "table" then
        return nil
    end

    local frames = {}
    for i = #backtrace, 1, -1 do
        local instruction_addr = normalize_hex_address(backtrace[i])
        if instruction_addr then
            local number_address = parse_hex_address(backtrace[i])
            local module, module_base = find_crash_module(modules, number_address)
            local module_name = get_module_name(module)
            local frame = {
                instruction_addr = instruction_addr,
                ["function"] = make_native_frame_key(backtrace[i], modules) or instruction_addr,
                in_app = false
            }

            if module_name then
                frame.module = tostring(module_name)
                frame.package = tostring(module_name)
                frame.filename = tostring(module_name)
            end
            if module_base then
                frame.image_addr = normalize_hex_address(module_base)
                frame.addr_mode = "abs"
            end

            table.insert(frames, frame)
        end
    end

    if #frames == 0 then
        return nil
    end

    return frames
end

local function build_native_crash_fingerprint(signum, backtrace, modules)
    local fingerprint = {
        "native",
        tostring(sys.get_config_string("project.title") or ""),
        tostring(M.config and M.config.release or ""),
        tostring(M.config and M.config.environment or ""),
        tostring(signum or "")
    }

    if type(backtrace) == "table" then
        local added = 0
        for i = 1, #backtrace do
            local key = make_native_frame_key(backtrace[i], modules)
            if key then
                table.insert(fingerprint, key)
                added = added + 1
                if added >= CRASH_FINGERPRINT_FRAME_LIMIT then
                    break
                end
            end
        end
    end

    return fingerprint
end

local function build_crash_report(handle)
    local backtrace = safe_call(crash.get_backtrace, handle) or {}
    local modules = safe_call(crash.get_modules, handle) or {}
    local user_fields = collect_crash_user_fields(handle)
    local sys_fields = collect_crash_sys_fields(handle)
    local signum = safe_call(crash.get_signum, handle)

    return {
        signum = signum,
        extra_data = trim_text(safe_call(crash.get_extra_data, handle), get_crash_extra_text_limit()),
        backtrace_json = encode_extra(backtrace),
        backtrace_count = count_items(backtrace),
        modules_json = encode_extra(modules),
        module_count = count_items(modules),
        sys_fields_json = encode_extra(sys_fields),
        user_fields_json = encode_extra(user_fields),
        native_frames = build_native_crash_frames(backtrace, modules),
        native_fingerprint = build_native_crash_fingerprint(signum, backtrace, modules)
    }
end

local function make_crash_report_extra(report)
    local extra = {}
    if type(report) ~= "table" then
        return extra
    end

    for key, value in pairs(report) do
        if key ~= "native_frames" and key ~= "native_fingerprint" then
            extra[key] = value
        end
    end

    return extra
end

local function make_hard_crash_callback_error(report)
    return {
        source = "crash",
        message = "Previous Defold native crash",
        type = "DefoldNativeCrash",
        value = "Previous Defold native crash" .. (report and report.signum and (" signal " .. tostring(report.signum)) or ""),
        traceback = report and report.backtrace_json or nil,
        stacktrace_frames = report and report.native_frames or nil,
        fingerprint = report and report.native_fingerprint or nil,
        event_platform = "c",
        fatal = true,
        extra = make_crash_report_extra(report)
    }
end

local function add_lua_traceback_frame(frames, filename, line, fn_name)
    if filename == "[C]" then
        return
    end

    local lineno = tonumber(line)
    local frame = {
        filename = filename,
        ["function"] = fn_name or "?",
        in_app = true
    }

    if lineno and lineno > 0 then
        frame.lineno = lineno
    end

    table.insert(frames, 1, frame)
end

local function parse_lua_traceback_frames(traceback)
    if type(traceback) ~= "string" then
        return nil
    end

    local frames = {}
    for line in string.gmatch(traceback, "[^\r\n]+") do
        local filename, lineno, fn_name = string.match(line, "^%s*(.+):(%-?%d+): in function '([^']+)'")
        if not filename then
            filename, lineno, fn_name = string.match(line, "^%s*(.+):(%-?%d+): in function <([^>]+)>")
        end
        if not filename then
            filename, lineno, fn_name = string.match(line, "^%s*(.+):(%-?%d+): in function (.+)$")
        end
        if not filename then
            filename, lineno = string.match(line, "^%s*(.+):(%-?%d+): in main chunk$")
            fn_name = filename and "main chunk" or nil
        end

        if filename then
            add_lua_traceback_frame(frames, filename, lineno, fn_name)
        end
    end

    if #frames == 0 then
        return nil
    end

    return frames
end

local function make_exception_value(err)
    local exception = {
        type = err.type or err.message or "Error",
        value = err.value or err.traceback or err.message or "Error",
        mechanism = err.mechanism or {
            type = err.source or "generic",
            handled = not err.fatal
        }
    }

    local frames = err.stacktrace_frames
    if type(frames) ~= "table" then
        frames = parse_lua_traceback_frames(err.traceback)
    end
    if frames then
        exception.stacktrace = {
            frames = frames
        }
    end

    return exception
end

local function make_exception_fingerprint(err, exception)
    if type(err.fingerprint) == "table" then
        return err.fingerprint
    end

    if type(err.fingerprint) == "string" then
        return { err.fingerprint }
    end

    local frames = exception.stacktrace and exception.stacktrace.frames
    if type(frames) ~= "table" or #frames == 0 then
        return nil
    end

    local frame = frames[#frames]
    return {
        "lua",
        tostring(M.config and M.config.release or ""),
        tostring(exception.type or "Error"),
        tostring(frame.filename or ""),
        tostring(frame["function"] or ""),
        tostring(frame.lineno or "")
    }
end

--- This function helps to throttle the amount of messages your game is sending to not spam Sentry servers.
-- Default rate limit: 10 messages per 300 seconds.
-- @tparam table transactions A table containing transaction entries
-- @treturn boolean Returns true if the transaction was added, false if throttled
local function add_transaction(transactions)
    table.insert(transactions, { time = socket.gettime() })

    if #transactions > 10 then
        local time = transactions[1].time

        if time > socket.gettime() - 300 then
            -- Throttle!
            table.remove(transactions) -- pop
            return false
        else
            table.remove(transactions, 1) -- shift
        end
    end

    return true
end

--- Parses a host and port from a given host string.
-- @tparam string protocol The protocol being used (e.g., 'http' or 'https')
-- @tparam string host The host string, which may include a port number
-- @treturn string|nil The parsed host name, or nil if parsing fails
-- @treturn number|nil The parsed port number, or nil if parsing fails
-- @treturn string|nil An error message if parsing fails, or nil on success
local function parse_host_port(protocol, host)
    local i = string.find(host, ":")
    if not i then
        return host, protocol == 'https' and 443 or 80
    end

    local port_str = string.sub(host, i + 1)
    local port = tonumber(port_str)
    if not port then
        return nil, nil, "illegal port: " .. port_str
    end

    return string.sub(host, 1, i - 1), port
end

--- Parses DSN string
-- @tparam string dsn The DSN string to parse
-- @tparam[opt] table obj The table to store the parsed DSN fields
-- @treturn table|nil The parsed DSN table, or nil if parsing fails
-- @treturn string|nil An error message if parsing fails, or nil on success
local function parse_dsn(dsn, obj)
    if not obj then
        obj = {}
    end
    assert(type(obj) == "table")

    -- '{PROTOCOL}://{PUBLIC_KEY}@{HOST}/{PATH}{PROJECT_ID}'
    obj.protocol, obj.public_key, obj.long_host, obj.path, obj.project_id =
        string.match(dsn, "^([^:]+)://([^@]+)@([^/]+)(.*/)(.+)$")

    if obj.protocol and obj.public_key and obj.long_host and obj.project_id then
        local host, port, err = parse_host_port(obj.protocol, obj.long_host)

        if not host then
            return nil, err
        end

        obj.host = host
        obj.port = port

        obj.request_uri = string.format("%sapi/%s/store/", obj.path, obj.project_id)
        obj.server = string.format("%s://%s:%d%s", obj.protocol, obj.host, obj.port, obj.request_uri)

        return obj
    end

    return nil, "failed to parse DSN string"
end

--- Generates a callback function for handling Sentry API responses
-- @tparam function|nil next The optional callback function to be called after processing the response
-- @treturn function The generated callback function
-- @usage local callback = request_callback(function(id, err) print(id, err) end)
local function request_callback(next)
    return function(self, id, resp)
        if type(resp) == "table" and resp.status == 200 then
            local ok, retval = pcall(json.decode, resp.response)
            if ok then
                -- valid response
                if next then
                    next(retval.id, nil)
                end
            else
                -- error
                if next then
                    next(nil, "Decode error: " .. tostring(retval))
                end
            end
        else
            if M.config.debug then
                log_print("Invalid request, response status " .. tostring(resp and resp.status))
            end
            if next then
                next(nil, "Response status " .. tostring(resp and resp.status))
            end
        end
    end
end

--- Creates a new event structure for Sentry reporting.
-- https://develop.sentry.dev/sdk/event-payloads/
-- @treturn table A new event table with initialized fields
local function new_event()
    local event = {}
    event.event_id = generate_event_id()
    event.timestamp = socket.gettime()
    -- 'javascript' says Sentry server to catch user IP from request. TODO: ask Sentry devs about this issue.
    event.platform = "javascript" -- important!
    event.logger = LOGGER_NAME

    event.release = M.config.release
    event.dist = M.config.dist
    event.environment = M.config.environment
    event.user = M.config.user

    event.tags = {}
    event.extra = {}

    if string.len(APP_PATH) > 0 then
        event.tags["application_path"] = APP_PATH
    end

    for k, v in pairs(ENGINE_INFO) do
        local s = tostring(v)
        if string.len(s) > 0 then
            event.tags["engine_info." .. k] = s
        end
    end

    for k, v in pairs(SYS_INFO) do
        local s = tostring(v)
        if string.len(s) > 0 then
            if k ~= "system_version" then
                event.tags["sys_info." .. k] = s
            end
        end
    end

    event.tags["project.version"] = sys.get_config_string("project.version")

    if html5 then
        event.request = {
            url = html5.run("window.location.href"),
            headers = {
                ["User-Agent"] = html5.run("window.navigator.userAgent")
            }
        }
    else
        event.contexts = {
            os = {
                name = SYS_INFO.system_name
            }
        }
    end

    apply_gpu_info(event)

    return event
end

local function compress_post_data(post_data, headers)
    if not M.config.compress_requests then
        return post_data
    end

    if type(zlib) ~= "table" or type(zlib.deflate) ~= "function" then
        if M.config.debug then
            log_print("Request compression unavailable: zlib.deflate is missing")
        end
        return post_data
    end

    local ok, compressed_data = pcall(zlib.deflate, post_data)
    if not ok then
        if M.config.debug then
            log_print("Request compression failed: " .. tostring(compressed_data))
        end
        return post_data
    end
    if type(compressed_data) ~= "string" then
        if M.config.debug then
            log_print("Request compression failed: zlib.deflate returned " .. type(compressed_data))
        end
        return post_data
    end

    headers["Content-Encoding"] = "deflate"
    if M.config.debug then
        log_print(string.format(
            "Compressed request payload: %d -> %d bytes",
            string.len(post_data),
            string.len(compressed_data)
        ))
    end
    return compressed_data
end

--- Sends the JSON-encoded event data to the Sentry server.
-- @tparam string json_str The JSON-encoded event data to send.
-- @tparam[opt] function callback A callback function to be called after the request is completed.
local function send(json_str, callback)
    local url = M.obj.server .. "?sentry_version=7&sentry_key=" .. M.obj.public_key
    local method = "POST"
    local headers = { ["Content-Type"] = "application/json" }
    if not html5 then
        headers["User-Agent"] = USER_AGENT
    end
    local post_data = json_str
    local options = {
        timeout = M.config.send_timeout
    }

    local cb_handler = request_callback(callback)
    if M.config.dry_run then
        if M.config.debug then
            log_print("Sending http request (dry run)")
        end
        cb_handler(M.obj, "(dry run)", { response = json.encode({ id = "(dry run)" }), status = 200 })
    else
        post_data = compress_post_data(post_data, headers)
        if M.config.debug then
            log_print("Sending event to " .. M.obj.server)
        end
        http.request(url, method, cb_handler, headers, post_data, options)
    end
end

local function error_handler(source, message, traceback)
    local error = {
        source = source,
        message = message,
        traceback = traceback,
        mechanism = {
            type = source or "lua",
            handled = false
        }
    }
    local pstatus, perr = pcall(M.capture_exception, error)
    if not pstatus then
        log_print("Exception capture error " .. tostring(perr))
    end

    if M.config.on_soft_crash then
        pstatus, perr = pcall(M.config.on_soft_crash, error)
        if not pstatus then
            log_print("Soft crash callback error " .. tostring(perr))
        end
    end
end

---
--- PUBLIC API
---

--- Returns whether Sentinel has been initialized.
-- @treturn boolean True after successful initialization
function M.is_initialized()
    return state.initialized
end

--- Returns a copy of Sentinel's runtime state.
-- @treturn table State snapshot
function M.get_state()
    local copy = {}
    for key, value in pairs(state) do
        copy[key] = value
    end
    return copy
end

--- Sets a Defold native crash user field.
-- @tparam number|string index Crash user field index, or a configured name
-- @tparam any value Value to store in the native crash user field
-- @treturn boolean True when the field was written
-- @treturn string|nil Error message on failure
function M.set_crash_user_field(index, value)
    local resolved_index = index
    if type(index) ~= "number" then
        if type(M.config) == "table" and type(M.config.crash_user_field_names) == "table" then
            resolved_index = M.config.crash_user_field_names[index]
        end
    end

    if type(resolved_index) ~= "number" then
        return false, "crash user field index is invalid"
    end

    if type(crash) ~= "table" or type(crash.set_user_field) ~= "function" then
        return false, "crash.set_user_field unavailable"
    end

    local text = trim_text(value, get_crash_user_field_size()) or ""
    local _, err = safe_call(crash.set_user_field, resolved_index, text)
    if err then
        return false, tostring(err)
    end

    return true, nil
end

--- Writes a native crash dump through Defold's crash API.
-- @treturn boolean True when the dump was written
-- @treturn string|nil Error message on failure
function M.write_crash_dump()
    if type(crash) ~= "table" or type(crash.write_dump) ~= "function" then
        set_status("Native crash dump failed: crash.write_dump unavailable", false)
        return false, "crash.write_dump unavailable"
    end

    local _, err = safe_call(crash.write_dump)
    if err then
        local message = "Native crash dump failed: " .. tostring(err)
        set_status(message, false)
        return false, message
    end

    set_status("Native crash dump written", true)
    return true, nil
end

--- Reports the previous native crash dump, if one exists.
-- @tparam[opt] table event_overrides Message, tags, extra, and callback overrides
-- @treturn boolean True when a previous crash report was submitted
-- @treturn string|nil Error message on failure
function M.report_previous_crash(event_overrides)
    if type(M.config) ~= "table" then
        set_status("Sentry is not initialized", false)
        return false, "initialize first"
    end

    if state.previous_crash_checked then
        set_status("Previous native crash already checked", true)
        return false, "previous native crash already checked"
    end

    state.previous_crash_checked = true

    if type(crash) ~= "table" or type(crash.load_previous) ~= "function" then
        set_status("Previous native crash failed: crash.load_previous unavailable", false)
        return false, "crash.load_previous unavailable"
    end

    local handle, load_err = safe_call(crash.load_previous)
    if not handle then
        if load_err then
            local message = "Previous native crash load failed: " .. tostring(load_err)
            set_status(message, false)
            return false, message
        end

        set_status("No previous native crash dump", true)
        return false, nil
    end

    state.previous_crash_found = true

    local report = build_crash_report(handle)
    safe_call(crash.release, handle)

    local event = make_hard_crash_callback_error(report)
    event.tags = {
        kind = "defold_crash",
        platform = tostring(SYS_INFO.system_name)
    }
    event.extra = make_crash_report_extra(report)

    apply_event_overrides(event, M.config.previous_crash_event)
    apply_event_overrides(event, event_overrides)

    local ok, captured = pcall(M.capture_exception, event)
    if not ok then
        state.previous_crash_reported = false
        local message = "Previous native crash capture failed: " .. tostring(captured)
        set_status(message, false)
        return false, message
    end

    state.previous_crash_reported = captured ~= false

    if M.config.on_hard_crash then
        local pstatus, perr = pcall(M.config.on_hard_crash, make_hard_crash_callback_error(report))
        if not pstatus then
            log_print("Hard crash callback error " .. tostring(perr))
        end
    end

    if state.previous_crash_reported then
        return true, nil
    end

    return false, state.last_error
end

--- Initialize Sentinel's Sentry Client.
-- Configuration should happen as early as possible in your application's lifecycle.
-- @tparam table config Configuration table
-- @tparam string config.dsn The DSN tells the SDK where to send the events
-- @tparam[opt=false] boolean config.debug Turn on to debug and check what data Sentinel sends
-- @tparam[opt=false] boolean config.dry_run If true, don't actually send data to Sentry
-- @tparam[opt=true] boolean config.compress_requests Compress outgoing Sentry requests with deflate
-- @tparam[opt=true] boolean config.collect_gpu_info Collect Defold/native GPU context once during init
-- @tparam[opt=128] number config.gpu_extensions_limit Maximum number of graphics extensions stored in event.extra.defold_graphics
-- @tparam[opt=false] boolean config.gameanalytics Whether to duplicate errors to GameAnalytics if it's installed
-- @tparam[opt=30] number config.send_timeout HTTP request timeout
-- @tparam[opt=true] boolean config.set_error_handler Install a custom Lua error handler
-- @tparam[opt=true] boolean config.load_previous_crash Load the previous crash dump if it exists
-- @tparam[opt] table config.extra Extra data to send with every event
-- @tparam[opt] table config.tags Tags to send with every event
-- @tparam[opt] function config.on_soft_crash Callback function for soft crashes
-- @tparam[opt] function config.on_hard_crash Callback function for hard crashes
-- @tparam[opt] string config.release Project's release ID. Defaults to project.title@project.version
-- @tparam[opt] string config.dist The distribution. Used to disambiguate build or deployment variants
-- @tparam[opt] string config.environment The environment. This string is freeform. E.g., 'staging' vs 'prod'
-- @tparam[opt] table config.user User information to include with events
-- @tparam[opt=8192] number config.crash_extra_text_limit Text limit for encoded native crash fields
-- @tparam[opt] table config.crash_user_field_names Optional name-to-index mapping for crash user fields
-- @tparam[opt] table config.previous_crash_event Optional event overrides for previous native crash reports
function M.init(config)
    assert(type(config) == "table", "`config` should be a table.")
    M.config = config

    assert(type(M.config.dsn) == "string", "`config.dsn` is required and should be a string.")

    -- Default settings
    if type(M.config.send_timeout) ~= "number" then
        M.config.send_timeout = 30 -- seconds
    end
    if type(M.config.set_error_handler) ~= "boolean" then
        M.config.set_error_handler = true
    end
    if type(M.config.load_previous_crash) ~= "boolean" then
        M.config.load_previous_crash = true
    end
    if type(M.config.compress_requests) ~= "boolean" then
        M.config.compress_requests = true
    end
    if type(M.config.collect_gpu_info) ~= "boolean" then
        M.config.collect_gpu_info = true
    end
    if type(M.config.gpu_extensions_limit) ~= "number" then
        M.config.gpu_extensions_limit = DEFAULT_GPU_EXTENSIONS_LIMIT
    end
    if type(M.config.crash_extra_text_limit) ~= "number" then
        M.config.crash_extra_text_limit = DEFAULT_CRASH_EXTRA_TEXT_LIMIT
    end
    if type(M.config.release) ~= "string" or M.config.release == "" then
        M.config.release = make_default_release()
    end

    --
    local err
    M.obj, err = parse_dsn(M.config.dsn)
    assert(err == nil, "Invalid the DSN url.")

    M.transactions = {}

    M.config.extra = M.config.extra or {}
    M.config.tags = M.config.tags or {}
    M.gpu_info = collect_gpu_info()

    if M.config.set_error_handler then
        sys.set_error_handler(error_handler)
    end

    if M.config.debug then
        log_print(USER_AGENT .. ", init OK")
    end

    state.initialized = true
    set_status("Sentry initialized", true)

    if M.config.load_previous_crash then
        M.report_previous_crash()
    end

    return true
end

--- Manually adds a breadcrumb whenever something interesting happens.
-- Sentry uses breadcrumbs to create a trail of events that happened prior to an issue.
-- These events are very similar to traditional logs, but can record more rich structured data.
-- - https://docs.sentry.io/platforms/javascript/guides/vue/enriching-events/breadcrumbs/
-- - https://docs.sentry.io/development/sdk-dev/event-payloads/breadcrumbs/
-- @tparam table breadcrumb A table containing breadcrumb information
-- @tparam string breadcrumb.category The category of the breadcrumb
-- @tparam string breadcrumb.message The message content of the breadcrumb
-- @usage sentry.add_breadcrumb({ category = "log", message = "Test breadcrumb message" })
function M.add_breadcrumb(breadcrumb)
    if type(M.config) ~= "table" then
        return false
    end

    if M.breadcrumbs == nil then
        M.breadcrumbs = {}
    end

    if type(breadcrumb) ~= "table" then
        breadcrumb = {}
    end
    breadcrumb.timestamp = socket.gettime()

    table.insert(M.breadcrumbs, breadcrumb)
    if #M.breadcrumbs > 10 then
        table.remove(M.breadcrumbs, 1)
    end

    return true
end

--- Set a globally defined tag.
-- This function allows you to set a tag that will be included in all future error reports or messages.
-- @tparam string key The key for the tag.
-- @tparam string|number|boolean value The value.
-- @usage sentry.set_tag("environment", "production")
-- @usage sentry.set_tag("user_id", 12345)
function M.set_tag(key, value)
    if type(M.config) ~= "table" then
        return false
    end

    M.config.tags[key] = value
    return true
end

--- Sets globally defined extra data.
-- This function allows you to set extra data that will be included in all future error reports or messages.
-- @tparam string key The key for the extra data.
-- @tparam string|number|boolean value The value.
-- @usage sentry.set_extra("user_level", 42)
-- @usage sentry.set_extra("last_checkpoint", "boss_room")
function M.set_extra(key, value)
    if type(M.config) ~= "table" then
        return false
    end

    M.config.extra[key] = value
    return true
end

--- Capture an error, i.e. send data to Sentry about the error.
-- If you set a global error handler, then you don't need to call this function.
-- @tparam table err Error information
-- @tparam string err.message Error message
-- @tparam[opt] string err.traceback Error traceback
-- @tparam[opt] string err.source Error source
-- @tparam[opt] boolean err.fatal Whether the error is fatal
-- @tparam[opt] table err.tags Additional tags to include
-- @tparam[opt] table err.extra Additional extra data to include
-- @tparam[opt] function err.callback A function to be called after the message is sent, with parameters (id, err_str)
-- @usage
-- local err = {
--     message = "Division by zero",
--     traceback = debug.traceback(),
--     source = "math_operations.lua",
--     fatal = false,
--     tags = {level = "boss"},
--     extra = {input_value = 0},
--     callback = function(id, err_str)
--         if id then
--             print("Captured with ID: " .. tostring(id))
--         else
--             print("Failed to capture error: " .. err_str)
--         end
--     end
-- }
-- sentry.capture_exception(err)
function M.capture_exception(err)
    assert(type(M.config) == "table", "initialize first")
    assert(type(err) == "table", "`capture_exception` expects a table.")
    err = clone_event(err)
    local callback = wrap_capture_callback(err.callback)

    if not add_transaction(M.transactions) then
        local message = "Too much messages per minute."
        if err.callback then
            callback(nil, message)
        else
            set_status("Sentry send failed: " .. message, false)
            log_print("Dropping the message, too much messages per minute.")
        end
        return false, message
    end

    local gameanalytics = rawget(_G, "gameanalytics")
    if M.config.gameanalytics and type(gameanalytics) == "table" and type(gameanalytics.addErrorEvent) == "function" then
        gameanalytics.addErrorEvent({
            severity = err.fatal and "Critical" or "Error",
            message = (err.message or "Error") .. "\n" .. tostring(err.traceback or "")
        })
    end

    local event = new_event()
    if type(err.event_platform) == "string" then
        event.platform = err.event_platform
    end

    if err.fatal then
        event.level = "fatal"
    else
        event.level = "error"
    end

    local exception = make_exception_value(err)
    event.message = err.message or "Error"
    event.exception = {
        values = {
            exception
        }
    }
    event.fingerprint = make_exception_fingerprint(err, exception)

    event.tags["source"] = err.source

    merge_kv(event.tags, M.config.tags)
    merge_kv(event.extra, M.config.extra)

    merge_kv(event.tags, err.tags)
    merge_kv(event.extra, err.extra)

    if M.breadcrumbs then
        event.breadcrumbs = M.breadcrumbs
    end

    if next(event.extra) == nil then
        event.extra = nil
    end

    local json_str = json.encode(event)
    if M.config.debug then
        log_print("JSON payload " .. json_str)
    end
    send(json_str, function(id, err_str)
        if id and M.config.debug then
            log_print("Exception is recorded as " .. id)
        end

        callback(id, err_str)
    end)
    return true, nil
end

--- Captures a bare message to be sent to Sentry.
-- @tparam table msg A table containing message details
-- @tparam string msg.message The textual content of the message
-- @tparam[opt="info"] string msg.level The severity level of the message. Can be "fatal", "error", "warning", "info", or "debug"
-- @tparam[opt] table msg.tags Additional tags to include
-- @tparam[opt] table msg.extra Additional extra data to include
-- @tparam[opt] function msg.callback A function to be called after the message is sent, with parameters (id, err_str)
-- @usage
-- sentry.capture_message({
--     message = "User performed action X",
--     level = "info",
--     tags = {group = "newbie"},
--     extra = {user_id = "12345", inventory = "sword, shield, potion"},
--     callback = function(id, err) print(id, err) end
-- })
function M.capture_message(msg)
    assert(type(M.config) == "table", "initialize first")
    assert(type(msg) == "table", "`capture_message` expects a table.")
    msg = clone_event(msg)
    local callback = wrap_capture_callback(msg.callback)

    if not add_transaction(M.transactions) then
        local message = "Too much messages per minute."
        if msg.callback then
            callback(nil, message)
        else
            set_status("Sentry send failed: " .. message, false)
            log_print("Dropping the message, too much messages per minute.")
        end
        return false, message
    end

    local event = new_event()

    event.message = msg.message or "N/A"
    event.level = msg.level or "info"

    merge_kv(event.tags, M.config.tags)
    merge_kv(event.extra, M.config.extra)

    merge_kv(event.tags, msg.tags)
    merge_kv(event.extra, msg.extra)

    if M.breadcrumbs then
        event.breadcrumbs = M.breadcrumbs
    end

    if next(event.extra) == nil then
        event.extra = nil
    end

    local json_str = json.encode(event)
    if M.config.debug then
        log_print("JSON payload " .. json_str)
    end
    send(json_str, function(id, err_str)
        if id and M.config.debug then
            log_print("Message is recorded as " .. id)
        end

        callback(id, err_str)
    end)
    return true, nil
end

return M
