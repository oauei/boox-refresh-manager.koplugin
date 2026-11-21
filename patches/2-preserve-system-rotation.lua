-- 2-preserve-system-rotation.lua
-- Runs during KOReader's early patch phase (before FileManager/ReaderUI startup rotation).
-- Keeps MainActivity in SCREEN_ORIENTATION_FULL_USER (13) so Android system autorotation
-- governs all four orientations (0, 90, 180, 270) even when KOReader starts upside-down.

local ok_a, android = pcall(require, "android")
if not (ok_a and android) then
    return
end

android._brm_rotation_patch_loaded = true
local SCREEN_ORIENTATION_FULL_USER = 13

if type(android.setScreenOrientation) == "function" and not android._brm_full_user_patched then
    android._brm_full_user_patched = true
    local orig_set = android.setScreenOrientation
    android._brm_orig_setScreenOrientation = orig_set
    android.setScreenOrientation = function(_orientation)
        return orig_set(SCREEN_ORIENTATION_FULL_USER)
    end
    pcall(orig_set, SCREEN_ORIENTATION_FULL_USER)
end

if type(android.screen) == "table" and type(android.screen.setOrientation) == "function"
    and not android.screen._brm_full_user_patched
then
    android.screen._brm_full_user_patched = true
    local orig_screen_set = android.screen.setOrientation
    android.screen._brm_orig_setOrientation = orig_screen_set
    android.screen.setOrientation = function(_orientation)
        return orig_screen_set(SCREEN_ORIENTATION_FULL_USER)
    end
    pcall(orig_screen_set, SCREEN_ORIENTATION_FULL_USER)
end

-- Also set Activity.setRequestedOrientation(SCREEN_ORIENTATION_FULL_USER) directly via JNI
if android.app ~= nil and android.app.activity ~= nil and android.app.activity.vm ~= nil and android.app.activity.clazz ~= nil
    and android.jni and type(android.jni.context) == "function"
then
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi and ffi then
        pcall(android.jni.context, android.jni, android.app.activity.vm, function(jni)
            local env = jni and jni.env
            if env == nil or env[0] == nil then return end
            local clazz = android.app.activity.clazz
            if clazz == nil then return end
            local act_cls = (env[0].GetObjectClass and env[0].GetObjectClass(env, clazz))
                or env[0].FindClass(env, "android/app/Activity")
            if act_cls ~= nil then
                local mid = env[0].GetMethodID(env, act_cls, "setRequestedOrientation", "(I)V")
                if mid ~= nil then
                    env[0].CallVoidMethod(env, clazz, mid, ffi.cast("jint", SCREEN_ORIENTATION_FULL_USER))
                end
                if env[0].ExceptionCheck and env[0].ExceptionCheck(env) ~= 0 then
                    env[0].ExceptionClear(env)
                end
                env[0].DeleteLocalRef(env, act_cls)
            elseif env[0].ExceptionCheck and env[0].ExceptionCheck(env) ~= 0 then
                env[0].ExceptionClear(env)
            end
        end)
    end
end
