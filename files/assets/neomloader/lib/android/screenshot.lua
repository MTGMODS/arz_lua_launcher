-- Own-app screenshots through Android Java APIs; call save() from a Lua coroutine.
local ffi = require('ffi')
local jni = require('android.jni-raw')
local env = require('android.jnienv')
local envu = require('android.jnienv-util')
local M = {IDLE = 0, PENDING = 1, SUCCESS = 2, ERROR = 3}
local bridge

local function load_bridge()
    if bridge then return bridge end
    if env.PushLocalFrame(32) ~= 0 then error('Cannot allocate JNI local frame') end
    local ok, class = pcall(function()
        local activity = jni.activity
        if activity == nil then error('Android Activity is unavailable') end
        local directory = envu.CallObjectMethod(activity, 'getCodeCacheDir', '()Ljava/io/File;')
        local directory_string = envu.CallObjectMethod(directory, 'getAbsolutePath', '()Ljava/lang/String;')
        local cache_path = envu.FromJString(directory_string)
        local path = cache_path .. '/mtg-screenshot.jar'
        local source = assert(io.open(getWorkingDirectory() .. '/lib/android/jar/mtg-screenshot.jar', 'rb'))
        local data = source:read('*a')
        source:close()
        assert(data, 'Cannot read screenshot JAR')
        -- Android 14 requires dynamically loaded code to be read-only. Keep the write
        -- descriptor open while marking the new file read-only, then write through it.
        os.remove(path)
        local target = assert(io.open(path, 'wb'))
        local written, failure = pcall(function()
            local file_class = env.FindClass_safe('java/io/File')
            local file = envu.CallConstructor(file_class, '(Ljava/lang/String;)V', env.NewStringUTF(path))
            local readonly = envu.CallBooleanMethod(file, 'setReadOnly', '()Z')
            if readonly ~= true and tonumber(readonly) ~= 1 then error('Cannot protect screenshot JAR') end
            assert(target:write(data))
        end)
        local closed, close_error = target:close()
        if not written then error(failure) end
        assert(closed, close_error)
        local parent = envu.CallObjectMethod(activity, 'getClassLoader', '()Ljava/lang/ClassLoader;')
        local dex_class = env.FindClass_safe('dalvik/system/DexClassLoader')
        local loader = envu.CallConstructor(dex_class,
            '(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V',
            env.NewStringUTF(path), directory_string, nil, parent)
        local loaded = envu.CallObjectMethod(loader, 'loadClass', '(Ljava/lang/String;)Ljava/lang/Class;',
            env.NewStringUTF('mtg.screenshot.ScreenshotBridge'))
        local clazz = ffi.cast('jclass', loaded)
        envu.CallStaticVoidMethod(clazz, 'init', '(Landroid/app/Activity;)V', activity)
        local global = env.NewGlobalRef(clazz)
        if global == nil then error('Cannot retain screenshot class') end
        return ffi.cast('jclass', global)
    end)
    env.PopLocalFrame(nil)
    if not ok then error(class) end
    bridge = ffi.gc(class, function(ref) pcall(env.DeleteGlobalRef, ref) end)
    return bridge
end

local function read_string(method)
    local value = envu.CallStaticObjectMethod(load_bridge(), method, '()Ljava/lang/String;')
    if value == nil then return '' end
    local ok, result = pcall(envu.FromJString, value)
    env.DeleteLocalRef(value)
    if not ok then error(result) end
    return result
end

function M.capture()
    local accepted = envu.CallStaticBooleanMethod(load_bridge(), 'capture', '()Z')
    return accepted == true or tonumber(accepted) == 1
end

function M.status()
    return tonumber(envu.CallStaticIntMethod(load_bridge(), 'getStatus', '()I'))
end

function M.result() return read_string('getResult') end
function M.error() return read_string('getError') end

-- Waits only in the calling coroutine. Java does PNG encoding and storage I/O.
-- cancel() stops the caller's wait; an accepted Android save can still finish.
function M.save(cancel)
    local ok, accepted = pcall(M.capture)
    if not ok then
        print('[Screenshot] ' .. tostring(accepted))
        return false, 'Не удалось загрузить Java-модуль скриншотов. Проверьте установку библиотеки.'
    end
    if not accepted then
        local read, reason = pcall(M.error)
        return false, read and reason ~= '' and reason or 'Предыдущий скриншот ещё сохраняется.'
    end
    for _ = 1, 600 do
        if cancel and cancel() then return false end
        local read, status = pcall(M.status)
        if not read then
            print('[Screenshot] ' .. tostring(status))
            return false, 'Не удалось получить состояние скриншота.'
        end
        if status == M.SUCCESS then
            local success, result = pcall(M.result)
            return true, success and result or ''
        elseif status == M.ERROR then
            local success, reason = pcall(M.error)
            return false, success and reason ~= '' and reason or 'Не удалось сохранить скриншот.'
        elseif status ~= M.PENDING then
            return false, 'Сохранение скриншота не было запущено.'
        end
        wait(50)
    end
    return false, 'Скриншот сохраняется слишком долго. Проверьте Галерею перед повтором.'
end

return M
