-- main.lua
-- Boox Refresh Manager: Refresh coalescing, waveform clamping, and SurfaceFlinger app-scope EPD override
-- Eliminates full-screen white flashes when navigating menus and Bookshelf in Regal mode on Onyx Boox devices.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

-- Determine plugin path for relative requires
local plugin_name = (...)
local plugin_dir = ""
if type(plugin_name) == "string" then
    plugin_dir = plugin_name:match("(.-)[^/%.]+$") or ""
end

local WaveformClamper = require(plugin_dir .. "lib/waveform_clamper")
local RefreshCoalescer = require(plugin_dir .. "lib/refresh_coalescer")

local BooxRefreshManager = WidgetContainer:extend{
    name = "boox_refresh_manager",
    is_doc_only = false,
}

local orig_setDirty = nil
local orig_ui_imp = nil
local orig_fast_imp = nil
local orig_partial_imp = nil
local orig_full_imp = nil
local orig_reader_paging_onPan = nil
local orig_reader_paging_onPanRelease = nil
local orig_reader_paging_onSwipe = nil
local scroll_settle_cb = nil
local scroll_fallback_cb = nil
local active_scroll_view = nil
local active_scroll_rp = nil
local scroll_sf_disarmed = false
local scroll_releasing = false
local rescheduleScrollSettle = nil
local clearContinuousScrollState = nil
local cancelDitherOverrideTimer = nil

local JNI_OK = 0
local JNI_VERSION_1_6 = 0x00010006

local function getReaderRegalMode()
    if G_reader_settings and G_reader_settings.readSetting then
        local mode = G_reader_settings:readSetting("boox_refresh_manager_reader_regal_mode")
        if mode == "regal" or mode == "regal_plus" then
            return mode
        end
    end
    return "regal_plus"
end

local _REGAL_CONFIG_JSON = nil
local _REGAL_PLUS_CONFIG_JSON = nil

local function buildRegalAppConfigJSON(reader_regal_mode)
    local mode = (reader_regal_mode == "regal") and "regal" or "regal_plus"
    if mode == "regal" and _REGAL_CONFIG_JSON then
        return _REGAL_CONFIG_JSON
    elseif mode == "regal_plus" and _REGAL_PLUS_CONFIG_JSON then
        return _REGAL_PLUS_CONFIG_JSON
    end
    local update_mode = (mode == "regal") and 3 or 5
    local str = string.format(
        '{"activityConfigMap":{},"autoFreezeConfig":{"autoFreeze":true,"enable":true,"supportAutoFreeze":true},"autoStartConfig":{"autoStart":false,"enable":true,"supportAdjust":true},"colorConfigMap":{},"colorMode":"vivid","cssConfigMap":{},"dpiConfig":{"dpi":0,"enable":true},"enable":true,"extraConfig":{"allowSplashScreen":true,"enable":true,"forceFullScreen":false,"fullPMAccess":false,"fullPMAccessTimeout":300000,"useDialogBorder":false,"usePageKeyAsVolumeKey":true},"forceScrollRefreshClsList":["com.qmuiteam.qmui.arch.SwipeBackLayout","mozilla.components.browser.engine.gecko.GeckoEngineView$geckoView$1","com.dragon.reader.simple.slip.OverScrollView","com.dragon.read.reader.ui.ReaderOverScrollView"],"globalActivityConfig":{"clsName":"","disableScrollAnim":false,"displayConfig":{"bwMode":0,"cfaColorBrightness":0,"cfaColorSaturation":0,"cfaColorSaturationMin":60,"contrast":30,"ditherThreshold":128,"enable":true,"enhance":true,"monoLevel":0},"eacScrollStyle":2,"enable":false,"noteConfig":{"compatibleVersionCode":0,"enable":false,"globalStrokeStyle":{"enable":false,"strokeColor":-16777216,"strokeExtraArgs":[],"strokeParams":[],"strokeStyle":0,"strokeWidth":3},"repaintLatency":500,"styleMap":{},"supportNoteConfig":false},"paintConfig":{"antiAlisingType":0,"ditherBitmap":false,"enable":true,"fillBrightness":0,"fillContrast":0,"fillEAC":false,"iconBrightness":0,"iconContrast":0,"iconEAC":false,"iconThreshold":0,"imgEAC":false,"imgGamma":60,"quantBits":3,"textBold":false,"textEACType":0},"refreshConfig":{"animationDuration":0,"antiFlicker":0,"enable":true,"gcInterval":20,"refreshModeAlias":"%s","refreshModeIndex":"refresh_mode_1","supportRegal":true,"turbo":0,"updateMode":%d,"useGCForNewSurface":false},"scrollRefreshDelay":1000},"globalCSSConfig":{"clsName":"","customCSS":"","enable":true,"fontBold":false,"fontColor":0,"fontSize":100},"keyboardConfig":{"enable":true,"pageKeyMode":1},"networkConfig":{"enable":true,"overrideRules":0},"pkgName":"org.koreader.launcher","rotationConfig":{"enable":true,"overrideRotation":-1},"scrollArgs":{"duration":600,"endXPercent":0.5,"endYPercent":0.8,"sampleTime":16,"startXPercent":0.5,"startYPercent":0.2},"scrollViewWhiteList":[],"supportEAC":false}',
        mode,
        update_mode
    )
    if mode == "regal" then
        _REGAL_CONFIG_JSON = str
    else
        _REGAL_PLUS_CONFIG_JSON = str
    end
    return str
end

_REGAL_CONFIG_JSON = buildRegalAppConfigJSON("regal")
_REGAL_PLUS_CONFIG_JSON = buildRegalAppConfigJSON("regal_plus")
local OPTIMAL_REGAL_APP_CONFIG_JSON = _REGAL_PLUS_CONFIG_JSON

local function buildSmoothAppConfigJSON()
    return '{"activityConfigMap":{},"autoFreezeConfig":{"autoFreeze":true,"enable":true,"supportAutoFreeze":true},"autoStartConfig":{"autoStart":false,"enable":true,"supportAdjust":true},"colorConfigMap":{},"colorMode":"vivid","cssConfigMap":{},"dpiConfig":{"dpi":0,"enable":true},"enable":true,"extraConfig":{"allowSplashScreen":true,"enable":true,"forceFullScreen":false,"fullPMAccess":false,"fullPMAccessTimeout":300000,"useDialogBorder":false,"usePageKeyAsVolumeKey":true},"forceScrollRefreshClsList":["com.qmuiteam.qmui.arch.SwipeBackLayout","mozilla.components.browser.engine.gecko.GeckoEngineView$geckoView$1","com.dragon.reader.simple.slip.OverScrollView","com.dragon.read.reader.ui.ReaderOverScrollView"],"globalActivityConfig":{"clsName":"","disableScrollAnim":false,"displayConfig":{"bwMode":0,"cfaColorBrightness":0,"cfaColorSaturation":0,"cfaColorSaturationMin":60,"contrast":30,"ditherThreshold":128,"enable":true,"enhance":true,"monoLevel":0},"eacScrollStyle":1,"enable":true,"noteConfig":{"compatibleVersionCode":0,"enable":false,"globalStrokeStyle":{"enable":false,"strokeColor":-16777216,"strokeExtraArgs":[],"strokeParams":[],"strokeStyle":0,"strokeWidth":3},"repaintLatency":500,"styleMap":{},"supportNoteConfig":false},"paintConfig":{"antiAlisingType":0,"ditherBitmap":false,"enable":true,"fillBrightness":0,"fillContrast":0,"fillEAC":false,"iconBrightness":0,"iconContrast":0,"iconEAC":false,"iconThreshold":0,"imgEAC":false,"imgGamma":60,"quantBits":3,"textBold":false,"textEACType":0},"refreshConfig":{"animationDuration":0,"antiFlicker":0,"enable":true,"gcInterval":20,"refreshModeAlias":"smooth","refreshModeIndex":"refresh_mode_5","supportRegal":false,"turbo":7,"updateMode":2,"useGCForNewSurface":false},"scrollRefreshDelay":1000},"globalCSSConfig":{"clsName":"","customCSS":"","enable":true,"fontBold":false,"fontColor":0,"fontSize":100},"keyboardConfig":{"enable":true,"pageKeyMode":1},"networkConfig":{"enable":true,"overrideRules":0},"pkgName":"org.koreader.launcher","rotationConfig":{"enable":true,"overrideRotation":-1},"scrollArgs":{"duration":600,"endXPercent":0.5,"endYPercent":0.8,"sampleTime":16,"startXPercent":0.5,"startYPercent":0.2},"scrollViewWhiteList":[],"supportEAC":true}'
end

local SMOOTH_APP_CONFIG_JSON = buildSmoothAppConfigJSON()
local scroll_oec_smooth_active = false
local scroll_app_scope_dirty = false

local function isContinuousScrollSession()
    return active_scroll_view ~= nil and active_scroll_view.page_scroll == true
end

local function buildSmoothAppConfigJSON()
    return '{"activityConfigMap":{},"autoFreezeConfig":{"autoFreeze":true,"enable":true,"supportAutoFreeze":true},"autoStartConfig":{"autoStart":false,"enable":true,"supportAdjust":true},"colorConfigMap":{},"colorMode":"vivid","cssConfigMap":{},"dpiConfig":{"dpi":0,"enable":true},"enable":true,"extraConfig":{"allowSplashScreen":true,"enable":true,"forceFullScreen":false,"fullPMAccess":false,"fullPMAccessTimeout":300000,"useDialogBorder":false,"usePageKeyAsVolumeKey":true},"forceScrollRefreshClsList":["com.qmuiteam.qmui.arch.SwipeBackLayout","mozilla.components.browser.engine.gecko.GeckoEngineView$geckoView$1","com.dragon.reader.simple.slip.OverScrollView","com.dragon.read.reader.ui.ReaderOverScrollView"],"globalActivityConfig":{"clsName":"","disableScrollAnim":false,"displayConfig":{"bwMode":0,"cfaColorBrightness":0,"cfaColorSaturation":0,"cfaColorSaturationMin":60,"contrast":30,"ditherThreshold":128,"enable":true,"enhance":true,"monoLevel":0},"eacScrollStyle":1,"enable":true,"noteConfig":{"compatibleVersionCode":0,"enable":false,"globalStrokeStyle":{"enable":false,"strokeColor":-16777216,"strokeExtraArgs":[],"strokeParams":[],"strokeStyle":0,"strokeWidth":3},"repaintLatency":500,"styleMap":{},"supportNoteConfig":false},"paintConfig":{"antiAlisingType":0,"ditherBitmap":false,"enable":true,"fillBrightness":0,"fillContrast":0,"fillEAC":false,"iconBrightness":0,"iconContrast":0,"iconEAC":false,"iconThreshold":0,"imgEAC":false,"imgGamma":60,"quantBits":3,"textBold":false,"textEACType":0},"refreshConfig":{"animationDuration":0,"antiFlicker":0,"enable":true,"gcInterval":20,"refreshModeAlias":"smooth","refreshModeIndex":"refresh_mode_5","supportRegal":false,"turbo":7,"updateMode":2,"useGCForNewSurface":false},"scrollRefreshDelay":1000},"globalCSSConfig":{"clsName":"","customCSS":"","enable":true,"fontBold":false,"fontColor":0,"fontSize":100},"keyboardConfig":{"enable":true,"pageKeyMode":1},"networkConfig":{"enable":true,"overrideRules":0},"pkgName":"org.koreader.launcher","rotationConfig":{"enable":true,"overrideRotation":-1},"scrollArgs":{"duration":600,"endXPercent":0.5,"endYPercent":0.8,"sampleTime":16,"startXPercent":0.5,"startYPercent":0.2},"scrollViewWhiteList":[],"supportEAC":true}'
end

local SMOOTH_APP_CONFIG_JSON = buildSmoothAppConfigJSON()
local scroll_oec_smooth_active = false
local scroll_app_scope_dirty = false

local function isContinuousScrollSession()
    return active_scroll_view ~= nil and active_scroll_view.page_scroll == true
end

local function getAndroidModule()
    if package.loaded["android"] then
        return package.loaded["android"]
    end
    local ok, mod = pcall(require, "android")
    if ok and mod then
        return mod
    end
    return nil
end

local function clearJNIException(env)
    if env ~= nil and env[0] ~= nil and env[0].ExceptionCheck then
        if env[0].ExceptionCheck(env) ~= 0 then
            env[0].ExceptionClear(env)
            return true
        end
    end
    return false
end

local function runWithEnv(env, ffi, fn)
    local ok, res = pcall(fn, env, ffi)
    clearJNIException(env)
    if not ok and logger and logger.warn then
        logger.warn("[BooxRefreshManager] JNI error: " .. tostring(res))
    end
    return ok, res
end

-- Re-entrant-safe JNI helper: prefers KOReader's p_android.jni wrapper when available,
-- avoids detaching an already-attached JVM thread, and clears any pending Java exception
-- so ART never aborts on return.
local function withJNIEnv(p_android, fn)
    if not (p_android and p_android.app and p_android.app.activity and p_android.app.activity.vm) then
        return false
    end
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi then
        return false
    end

    local jvm = p_android.app.activity.vm
    if jvm == nil or jvm[0] == nil then
        return false
    end

    if p_android.jni then
        if type(p_android.jni.context) == "function" then
            local ok_ctx, ok_fn, res_fn = pcall(p_android.jni.context, p_android.jni, jvm, function(jni)
                local env = jni and jni.env
                if env == nil or env[0] == nil then
                    return false
                end
                return runWithEnv(env, ffi, fn)
            end)
            if ok_ctx then
                return ok_fn, res_fn
            end
        elseif p_android.jni.env ~= nil and p_android.jni.env[0] ~= nil then
            return runWithEnv(p_android.jni.env, ffi, fn)
        end
    end

    local env_ptr
    if type(jvm) == "table" then
        env_ptr = { [0] = nil }
    else
        local ok_alloc, ptr = pcall(ffi.new, "JNIEnv*[1]")
        if not ok_alloc or not ptr then
            return false
        end
        env_ptr = ptr
    end

    local void_ptr = (type(jvm) == "table") and env_ptr or ffi.cast("void**", env_ptr)
    local get_res = jvm[0].GetEnv(jvm, void_ptr, JNI_VERSION_1_6)
    local attached_here = false
    if get_res ~= JNI_OK then
        if jvm[0].AttachCurrentThread(jvm, env_ptr, nil) ~= JNI_OK then
            return false
        end
        attached_here = true
    end

    local env = env_ptr[0]
    if env == nil or env[0] == nil then
        if attached_here then
            jvm[0].DetachCurrentThread(jvm)
        end
        return false
    end

    local ok, res = runWithEnv(env, ffi, fn)
    if attached_here then
        jvm[0].DetachCurrentThread(jvm)
    end
    return ok, res
end

local function callStaticVUHMethod(env, vuh_cls, name, sig, ...)
    local mid = env[0].GetStaticMethodID(env, vuh_cls, name, sig)
    if mid ~= nil then
        env[0].CallStaticVoidMethod(env, vuh_cls, mid, ...)
    end
    clearJNIException(env)
end

local function callStaticVUHBooleanMethod(env, vuh_cls, name, sig, ...)
    local mid = env[0].GetStaticMethodID(env, vuh_cls, name, sig)
    local res = nil
    if mid ~= nil then
        res = env[0].CallStaticBooleanMethod(env, vuh_cls, mid, ...)
    end
    clearJNIException(env)
    return res
end

-- Resets byPass(0), applies UI animation scheme/anti-flicker, disables SurfaceFlinger's debouncer/Regal/dither,
-- and applies app-scope EPD mode so UI/Menu/Bookshelf partial buffer swaps update without waveform 16 white flashes.
local function disarmSurfaceFlingerRegal(env, ffi_mod, vuh_cls, epd_mode, anti_flicker, enable_dither, turbo_level, skip_app_scope)
    local target_epd_mode = epd_mode or WaveformClamper.ui_epd_mode or 5
    local target_anti_flicker = (anti_flicker ~= nil) and anti_flicker or 10
    local target_dither = (enable_dither == true) and 1 or 0

    callStaticVUHBooleanMethod(env, vuh_cls, "setDisplayScheme", "(I)Z", ffi_mod.cast("jint", 4))
    callStaticVUHMethod(env, vuh_cls, "antiFlicker", "(I)V", ffi_mod.cast("jint", target_anti_flicker))
    callStaticVUHMethod(env, vuh_cls, "byPass", "(I)V", ffi_mod.cast("jint", 0))
    callStaticVUHMethod(
        env,
        vuh_cls,
        "debouncer",
        "(ZIIII)V",
        ffi_mod.cast("jboolean", 0),
        ffi_mod.cast("jint", 0),
        ffi_mod.cast("jint", 0),
        ffi_mod.cast("jint", 0),
        ffi_mod.cast("jint", 0)
    )
    callStaticVUHMethod(env, vuh_cls, "enableRegal", "(Z)V", ffi_mod.cast("jboolean", 0))
    callStaticVUHMethod(env, vuh_cls, "enableDither", "(Z)V", ffi_mod.cast("jboolean", target_dither))
    if turbo_level ~= nil then
        callStaticVUHMethod(env, vuh_cls, "setTurbo", "(I)V", ffi_mod.cast("jint", turbo_level))
        callStaticVUHMethod(env, vuh_cls, "turbo", "(I)V", ffi_mod.cast("jint", turbo_level))
    end
    if skip_app_scope then
        return
    end
    if target_epd_mode == 2 then
        callStaticVUHMethod(env, vuh_cls, "setDebouncerTransientUpdateMode", "(I)V", ffi_mod.cast("jint", target_epd_mode))
        local mid_clear = env[0].GetStaticMethodID(env, vuh_cls, "clearAppScopeUpdate", "(I)V")
        if mid_clear ~= nil then
            env[0].CallStaticVoidMethod(env, vuh_cls, mid_clear, ffi_mod.cast("jint", 2))
            clearJNIException(env)
            env[0].CallStaticVoidMethod(env, vuh_cls, mid_clear, ffi_mod.cast("jint", 1))
            clearJNIException(env)
        else
            clearJNIException(env)
        end
    end

    local mid_scope = env[0].GetStaticMethodID(env, vuh_cls, "applyAppScopeUpdate", "(Ljava/lang/String;ZIII)V")
    if mid_scope ~= nil then
        env[0].CallStaticVoidMethod(
            env,
            vuh_cls,
            mid_scope,
            ffi_mod.cast("void*", nil),
            ffi_mod.cast("jboolean", 1),
            ffi_mod.cast("jint", 2),
            ffi_mod.cast("jint", target_epd_mode),
            ffi_mod.cast("jint", 0x7fffffff)
        )
        clearJNIException(env)

        local jstr_pkg = env[0].NewStringUTF(env, "org.koreader.launcher")
        if jstr_pkg ~= nil then
            env[0].CallStaticVoidMethod(
                env,
                vuh_cls,
                mid_scope,
                jstr_pkg,
                ffi_mod.cast("jboolean", 1),
                ffi_mod.cast("jint", 1),
                ffi_mod.cast("jint", target_epd_mode),
                ffi_mod.cast("jint", 0x7fffffff)
            )
            clearJNIException(env)
            env[0].DeleteLocalRef(env, jstr_pkg)
        else
            clearJNIException(env)
        end
    else
        clearJNIException(env)
    end
end

-- Restores native SurfaceFlinger Regal anti-ghosting, SCHEME_NORMAL, hardware dithering, and debouncer for ReaderUI.
local function armSurfaceFlingerRegalForReader(env, ffi_mod, vuh_cls, reader_regal_mode)
    local mode = reader_regal_mode or getReaderRegalMode()
    callStaticVUHMethod(env, vuh_cls, "byPass", "(I)V", ffi_mod.cast("jint", 0))
    local mid_scope = env[0].GetStaticMethodID(env, vuh_cls, "applyAppScopeUpdate", "(Ljava/lang/String;ZIII)V")
    if mid_scope ~= nil then
        env[0].CallStaticVoidMethod(
            env,
            vuh_cls,
            mid_scope,
            ffi_mod.cast("void*", nil),
            ffi_mod.cast("jboolean", 0),
            ffi_mod.cast("jint", 2),
            ffi_mod.cast("jint", 5),
            ffi_mod.cast("jint", 0)
        )
        clearJNIException(env)
        local jstr_pkg = env[0].NewStringUTF(env, "org.koreader.launcher")
        if jstr_pkg ~= nil then
            env[0].CallStaticVoidMethod(
                env,
                vuh_cls,
                mid_scope,
                jstr_pkg,
                ffi_mod.cast("jboolean", 0),
                ffi_mod.cast("jint", 1),
                ffi_mod.cast("jint", 5),
                ffi_mod.cast("jint", 0)
            )
            clearJNIException(env)
            env[0].DeleteLocalRef(env, jstr_pkg)
        else
            clearJNIException(env)
        end
    else
        clearJNIException(env)
    end
    for _, clear_flag in ipairs({ 0, 1, 2 }) do
        callStaticVUHMethod(env, vuh_cls, "clearAppScopeUpdate", "(I)V", ffi_mod.cast("jint", clear_flag))
    end
    callStaticVUHBooleanMethod(env, vuh_cls, "setDisplayScheme", "(I)Z", ffi_mod.cast("jint", 1))
    callStaticVUHMethod(env, vuh_cls, "antiFlicker", "(I)V", ffi_mod.cast("jint", 0))
    callStaticVUHMethod(env, vuh_cls, "enableDither", "(Z)V", ffi_mod.cast("jboolean", 1))
    if mode == "regal" then
        callStaticVUHMethod(
            env,
            vuh_cls,
            "debouncer",
            "(ZIIII)V",
            ffi_mod.cast("jboolean", 0),
            ffi_mod.cast("jint", 0),
            ffi_mod.cast("jint", 0),
            ffi_mod.cast("jint", 0),
            ffi_mod.cast("jint", 0)
        )
    else
        callStaticVUHMethod(
            env,
            vuh_cls,
            "debouncer",
            "(ZIIII)V",
            ffi_mod.cast("jboolean", 1),
            ffi_mod.cast("jint", 5),
            ffi_mod.cast("jint", 150),
            ffi_mod.cast("jint", 450),
            ffi_mod.cast("jint", 20)
        )
    end
    callStaticVUHMethod(env, vuh_cls, "enableRegal", "(Z)V", ffi_mod.cast("jboolean", 1))
    local transient_epd_mode = (mode == "regal") and 6 or 9
    callStaticVUHMethod(env, vuh_cls, "setDebouncerTransientUpdateMode", "(I)V", ffi_mod.cast("jint", transient_epd_mode))
end

local function withViewUpdateHelper(p_android, callback)
    withJNIEnv(p_android, function(env, ffi_mod)
        local vuh_cls = env[0].FindClass(env, "android/onyx/ViewUpdateHelper")
        if vuh_cls ~= nil then
            callback(env, ffi_mod, vuh_cls)
            env[0].DeleteLocalRef(env, vuh_cls)
        else
            clearJNIException(env)
        end
    end)
end

function BooxRefreshManager:applyHardwareDisplayScheme(p_android)
    withViewUpdateHelper(p_android, function(env, ffi, vuh_cls)
        disarmSurfaceFlingerRegal(env, ffi, vuh_cls)
        logger.info("[BooxRefreshManager] Disarmed SurfaceFlinger Regal: scheme(4), antiFlicker(10), byPass(0), debouncer(false), enableRegal(false), enableDither(false), applyAppScopeUpdate")
    end)
    return true
end

function BooxRefreshManager:applyOECAppConfig(p_android, json_str, save_mmkv)
    json_str = json_str or buildRegalAppConfigJSON(getReaderRegalMode())
    local save_flag = (save_mmkv == false) and 0 or 1
    local success = false
    withJNIEnv(p_android, function(env, ffi)
        local list_cls = env[0].FindClass(env, "java/util/ArrayList")
        if list_cls == nil then
            clearJNIException(env)
            return
        end

        local list_init = env[0].GetMethodID(env, list_cls, "<init>", "()V")
        local list_add = env[0].GetMethodID(env, list_cls, "add", "(Ljava/lang/Object;)Z")
        local list_obj = (list_init ~= nil) and env[0].NewObject(env, list_cls, list_init) or nil
        if list_obj == nil or list_add == nil then
            clearJNIException(env)
            if list_obj ~= nil then env[0].DeleteLocalRef(env, list_obj) end
            env[0].DeleteLocalRef(env, list_cls)
            return
        end

        local jstr = env[0].NewStringUTF(env, json_str)
        if jstr ~= nil then
            env[0].CallBooleanMethod(env, list_obj, list_add, jstr)
            clearJNIException(env)
            env[0].DeleteLocalRef(env, jstr)
        else
            clearJNIException(env)
        end

        local bundle_cls = env[0].FindClass(env, "android/os/Bundle")
        local bundle_obj = nil
        if bundle_cls ~= nil then
            local bundle_init = env[0].GetMethodID(env, bundle_cls, "<init>", "()V")
            local bundle_put_bool = env[0].GetMethodID(env, bundle_cls, "putBoolean", "(Ljava/lang/String;Z)V")
            if bundle_init ~= nil then
                bundle_obj = env[0].NewObject(env, bundle_cls, bundle_init)
                if bundle_obj ~= nil and bundle_put_bool ~= nil then
                    local save_key = env[0].NewStringUTF(env, "args_save_mmkv")
                    if save_key ~= nil then
                        env[0].CallVoidMethod(env, bundle_obj, bundle_put_bool, save_key, ffi.cast("jboolean", save_flag))
                        clearJNIException(env)
                        env[0].DeleteLocalRef(env, save_key)
                    else
                        clearJNIException(env)
                    end
                end
            else
                clearJNIException(env)
            end
        else
            clearJNIException(env)
        end

        if bundle_obj ~= nil then
            local helper_cls = env[0].FindClass(env, "android/onyx/optimization/EInkHelper")
            if helper_cls ~= nil then
                local mid = env[0].GetStaticMethodID(env, helper_cls, "applyAppConfigToService", "(Ljava/util/List;Landroid/os/Bundle;)V")
                if mid ~= nil then
                    env[0].CallStaticVoidMethod(env, helper_cls, mid, list_obj, bundle_obj)
                    if not clearJNIException(env) then
                        logger.info("[BooxRefreshManager] Successfully called EInkHelper.applyAppConfigToService")
                        success = true
                    end
                else
                    logger.warn("[BooxRefreshManager] applyAppConfigToService methodID not found")
                    clearJNIException(env)
                end
                env[0].DeleteLocalRef(env, helper_cls)
            else
                logger.warn("[BooxRefreshManager] EInkHelper class not found")
                clearJNIException(env)
            end
        else
            logger.warn("[BooxRefreshManager] Failed to allocate android/os/Bundle for applyAppConfigToService")
            clearJNIException(env)
        end

        if bundle_obj ~= nil then env[0].DeleteLocalRef(env, bundle_obj) end
        if bundle_cls ~= nil then env[0].DeleteLocalRef(env, bundle_cls) end

        env[0].DeleteLocalRef(env, list_obj)
        env[0].DeleteLocalRef(env, list_cls)
    end)
    return success
end

function BooxRefreshManager:applyOptimalSettings()
    -- 1. Ensure KOReader avoid_flashing_ui, classic 1:1 scroll_method, and plugin enable flag are active
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting("avoid_flashing_ui", true)
        G_reader_settings:saveSetting("scroll_method", "classic")
        G_reader_settings:saveSetting("boox_refresh_manager_enabled", true)
        pcall(function() G_reader_settings:flush() end)
    end

    WaveformClamper.enabled = true
    RefreshCoalescer.enabled = true

    -- 2. Apply Boox OS E-Ink Center config first, then SurfaceFlinger display scheme / app-scope override
    local p_android = getAndroidModule()
    if p_android then
        self:applyOECAppConfig(p_android, buildRegalAppConfigJSON(getReaderRegalMode()))
        self:applyHardwareDisplayScheme(p_android)
    end
end

local function isValidNativeWindow(ffi_mod, win)
    if win == nil then
        return false
    end
    if type(win) == "cdata" and ffi_mod and ffi_mod.cast then
        local ok_ptr, addr = pcall(function()
            return tonumber(ffi_mod.cast("uintptr_t", win))
        end)
        if ok_ptr and (addr == nil or addr == 0) then
            return false
        end
    end
    return true
end

local mod_ffi = nil
local function getFFI()
    if mod_ffi == nil then
        local ok_ffi, ffi = pcall(require, "ffi")
        mod_ffi = (ok_ffi and ffi) or false
    end
    return mod_ffi or nil
end

local mod_BB = nil
local function getBlitBuffer()
    if mod_BB == nil then
        local ok_bb, BB = pcall(require, "ffi/blitbuffer")
        mod_BB = (ok_bb and BB) or false
    end
    return mod_BB or nil
end

local static_anw_buffer = nil
local static_arect = nil
local function getStaticBuffers(ffi)
    if not static_anw_buffer and ffi then
        local ok_buf, buf = pcall(ffi.new, "ANativeWindow_Buffer[1]")
        if ok_buf then static_anw_buffer = buf end
    end
    if not static_arect and ffi then
        local ok_rect, r = pcall(ffi.new, "ARect")
        if ok_rect then static_arect = r end
    end
    return static_anw_buffer, static_arect
end

function BooxRefreshManager:installScreenHooks(p_android)
    if not Screen or orig_ui_imp or not Screen.refreshUIImp then
        return
    end

    orig_ui_imp = Screen.refreshUIImp
    Screen.refreshUIImp = function(self_scr, x, y, w, h)
        if not WaveformClamper.enabled then
            return orig_ui_imp(self_scr, x, y, w, h)
        end

        if active_scroll_view and active_scroll_view.page_scroll == false and clearContinuousScrollState then
            clearContinuousScrollState()
        end

        local in_reader_doc = WaveformClamper.isReaderDocumentView()
        if in_reader_doc
            and not WaveformClamper.scroll_pan_active
            and not isContinuousScrollSession()
        then
            local active_android = p_android or getAndroidModule()
            local mode = getReaderRegalMode()
            withViewUpdateHelper(active_android, function(env, ffi_mod, vuh_cls)
                armSurfaceFlingerRegalForReader(env, ffi_mod, vuh_cls, mode)
                logger.info(string.format("[BooxRefreshManager] refreshUIImp armed SurfaceFlinger Regal (%s) for Reader: scheme(1), antiFlicker(0), byPass(0), clearAppScopeUpdate(0..2), enableRegal(true), enableDither(true), debouncer(%s)",
                    mode, tostring(mode ~= "regal")))
            end)
            scroll_sf_disarmed = false
            scroll_app_scope_dirty = true
            return orig_ui_imp(self_scr, x, y, w, h)
        end
        if not in_reader_doc then
            -- Menu/dialog/bookshelf UI redraws overwrite SurfaceFlinger epdMode; force Smooth re-assertion on next pan
            scroll_sf_disarmed = false
        end

        local active_android = p_android or getAndroidModule()
        local ok_imp, err_imp = pcall(function()
            local rx, ry, rw, rh
            local bb = self_scr.full_bb or self_scr.bb
            if bb then
                rx, ry, rw, rh = bb:getBoundedRect(x, y, w, h)
                rx, ry, rw, rh = bb:getPhysicalRect(rx, ry, rw, rh)
            else
                rx = x or 0
                ry = y or 0
                rw = w or (self_scr.getWidth and self_scr:getWidth() or 2480)
                rh = h or (self_scr.getHeight and self_scr:getHeight() or 1860)
            end

            local ffi = getFFI()
            if ffi and active_android and active_android.app
                and isValidNativeWindow(ffi, active_android.app.window)
                and active_android.lib
            then
                local s_buf, s_rect = getStaticBuffers(ffi)
                local buffer = s_buf or ffi.new("ANativeWindow_Buffer[1]")
                local dirty_rect = nil
                local screen_w = self_scr.getWidth and self_scr:getWidth() or 2480
                local screen_h = self_scr.getHeight and self_scr:getHeight() or 1860
                if rx and ry and rw and rh and (ry + rh > screen_h) and (ry + rh <= screen_w) then
                    screen_w, screen_h = screen_h, screen_w
                end
                local clamp_left = math.max(0, math.min(screen_w, rx or 0))
                local clamp_top = math.max(0, math.min(screen_h, ry or 0))
                local clamp_right = math.max(clamp_left, math.min(screen_w, (rx or 0) + (rw or screen_w)))
                local clamp_bottom = math.max(clamp_top, math.min(screen_h, (ry or 0) + (rh or screen_h)))

                if rw and rh and rw > 0 and rh > 0 and (rw < screen_w or rh < screen_h) then
                    if s_rect then
                        s_rect.left = clamp_left
                        s_rect.top = clamp_top
                        s_rect.right = clamp_right
                        s_rect.bottom = clamp_bottom
                        dirty_rect = s_rect
                    else
                        dirty_rect = ffi.new("ARect", { left = clamp_left, top = clamp_top, right = clamp_right, bottom = clamp_bottom })
                    end
                end

                if active_android.lib.ANativeWindow_lock(active_android.app.window, buffer, dirty_rect) == 0 then
                    local ok_blit, blit_err = pcall(function()
                        local BB = getBlitBuffer()
                        if BB then
                            local win_bb = nil
                            if buffer[0].format == 1 or buffer[0].format == 2 then
                                win_bb = BB.new(buffer[0].width, buffer[0].height, BB.TYPE_BBRGB32, buffer[0].bits, buffer[0].stride * 4, buffer[0].stride)
                            elseif buffer[0].format == 4 then
                                win_bb = BB.new(buffer[0].width, buffer[0].height, BB.TYPE_BBRGB16, buffer[0].bits, buffer[0].stride * 2, buffer[0].stride)
                            end
                            if win_bb then
                                local ext_bb = self_scr.full_bb or self_scr.bb
                                if ext_bb then
                                    win_bb:setInverse(ext_bb:getInverse())
                                    win_bb:setRotation(ext_bb:getRotation())
                                    if win_bb:getInverse() == 1 and BB.getUseCBB and BB:getUseCBB() then
                                        if win_bb:getType() == ext_bb:getType() then
                                            win_bb:invertblitFrom(ext_bb)
                                        else
                                            win_bb:blitFrom(ext_bb)
                                            win_bb:invertRect(0, 0, win_bb:getWidth(), win_bb:getHeight())
                                        end
                                    else
                                        win_bb:blitFrom(ext_bb)
                                    end
                                end
                            end
                        end
                    end)

                    -- Disarm SurfaceFlinger debouncer/Regal once per scroll pan (skip redundant per-frame JNI calls)
                    if WaveformClamper.scroll_pan_active and scroll_releasing and rescheduleScrollSettle then
                        rescheduleScrollSettle(0.15)
                    end
                    if not (WaveformClamper.scroll_pan_active and scroll_sf_disarmed) then
                        local keep_smooth = in_reader_doc and isContinuousScrollSession()
                        if keep_smooth and (scroll_app_scope_dirty or not scroll_oec_smooth_active) then
                            BooxRefreshManager:applyOECAppConfig(active_android, SMOOTH_APP_CONFIG_JSON, false)
                            scroll_oec_smooth_active = true
                            scroll_app_scope_dirty = false
                            if UIManager and UIManager.scheduleIn then
                                local epd_mode = WaveformClamper.scroll_epd_mode or 2
                                cancelDitherOverrideTimer()
                                scroll_dither_override_cb = function()
                                    scroll_dither_override_cb = nil
                                    if WaveformClamper.scroll_pan_active or isContinuousScrollSession() then
                                        local a_mod = getAndroidModule()
                                        if a_mod then
                                            withViewUpdateHelper(a_mod, function(env, ffi_mod, vuh_cls)
                                                disarmSurfaceFlingerRegal(env, ffi_mod, vuh_cls, epd_mode, 0, false, 7, true)
                                            end)
                                        end
                                    end
                                end
                                UIManager:scheduleIn(0.05, scroll_dither_override_cb)
                            end
                        end
                        withViewUpdateHelper(active_android, function(env, ffi_mod, vuh_cls)
                            if keep_smooth then
                                local epd_mode = WaveformClamper.scroll_epd_mode or 2
                                disarmSurfaceFlingerRegal(env, ffi_mod, vuh_cls, epd_mode, 0, false, 7, true)
                                logger.info(string.format("[BooxRefreshManager] Disarmed SurfaceFlinger Regal (Smooth epd=%d): antiFlicker(0), dither(false), turbo(7)", epd_mode))
                            else
                                disarmSurfaceFlingerRegal(env, ffi_mod, vuh_cls)
                                logger.info("[BooxRefreshManager] Disarmed SurfaceFlinger Regal: byPass(0), debouncer(false), enableRegal(false), enableDither(false), applyAppScopeUpdate")
                            end
                        end)
                        if keep_smooth then
                            scroll_sf_disarmed = true
                        else
                            scroll_app_scope_dirty = true
                        end
                    end

                    active_android.lib.ANativeWindow_unlockAndPost(active_android.app.window)
                    if not ok_blit then
                        logger.warn("[BooxRefreshManager] Blit operation failed: " .. tostring(blit_err))
                    end
                    if not (WaveformClamper.scroll_pan_active and scroll_sf_disarmed) then
                        logger.info(string.format("[BooxRefreshManager] ANativeWindow_lock with ARect: %d,%d to %d,%d",
                            clamp_left, clamp_top, clamp_right, clamp_bottom))
                    end
                else
                    orig_ui_imp(self_scr, x, y, w, h)
                end
            else
                orig_ui_imp(self_scr, x, y, w, h)
            end
        end)

        if not ok_imp then
            logger.warn("[BooxRefreshManager] refreshUIImp error, falling back: " .. tostring(err_imp))
            return orig_ui_imp(self_scr, x, y, w, h)
        end
        return true
    end

    local function wrapReaderRefreshImp(orig_imp, method_name)
        return function(self_scr, x, y, w, h)
            if not WaveformClamper.enabled then
                return orig_imp(self_scr, x, y, w, h)
            end
            if not WaveformClamper.isReaderDocumentView() then
                return Screen.refreshUIImp(self_scr, x, y, w, h)
            end
            if active_scroll_view and active_scroll_view.page_scroll == false and clearContinuousScrollState then
                clearContinuousScrollState()
            end
            if WaveformClamper.scroll_pan_active or isContinuousScrollSession() then
                return Screen.refreshUIImp(self_scr, x, y, w, h)
            end
            local active_android = p_android or getAndroidModule()
            local mode = getReaderRegalMode()
            withViewUpdateHelper(active_android, function(env, ffi_mod, vuh_cls)
                armSurfaceFlingerRegalForReader(env, ffi_mod, vuh_cls, mode)
                logger.info(string.format("[BooxRefreshManager] %s armed SurfaceFlinger Regal (%s) for Reader: scheme(1), antiFlicker(0), byPass(0), clearAppScopeUpdate(0..2), enableRegal(true), enableDither(true), debouncer(%s)",
                    method_name, mode, tostring(mode ~= "regal")))
            end)
            scroll_sf_disarmed = false
            scroll_app_scope_dirty = true
            return orig_imp(self_scr, x, y, w, h)
        end
    end

    if Screen.refreshFastImp and not orig_fast_imp then
        orig_fast_imp = Screen.refreshFastImp
        Screen.refreshFastImp = function(self_scr, x, y, w, h)
            if WaveformClamper.enabled and WaveformClamper.scroll_pan_active then
                if scroll_releasing and rescheduleScrollSettle then
                    rescheduleScrollSettle(0.15)
                end
                return Screen.refreshUIImp(self_scr, x, y, w, h)
            end
            return orig_fast_imp(self_scr, x, y, w, h)
        end
    end

    if Screen.refreshPartialImp and not orig_partial_imp then
        orig_partial_imp = Screen.refreshPartialImp
        Screen.refreshPartialImp = wrapReaderRefreshImp(orig_partial_imp, "refreshPartialImp")
    end

    if Screen.refreshFullImp and not orig_full_imp then
        orig_full_imp = Screen.refreshFullImp
        Screen.refreshFullImp = wrapReaderRefreshImp(orig_full_imp, "refreshFullImp")
    end
end

function BooxRefreshManager:init()
    BooxRefreshManager.instance = self

    -- Register with KOReader's main menu so Device > Boox Refresh Manager appears
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Read saved settings if present
    local enabled = true
    if G_reader_settings and G_reader_settings.readSetting then
        local setting_val = G_reader_settings:readSetting("boox_refresh_manager_enabled")
        if setting_val ~= nil then
            enabled = (setting_val == true)
        end
    end

    WaveformClamper.enabled = enabled
    WaveformClamper.init(UIManager, logger)

    RefreshCoalescer.enabled = enabled
    RefreshCoalescer.init(WaveformClamper, UIManager, Screen, logger)

    -- Hook UIManager:setDirty to clamp flashing waveforms in UI contexts
    if not orig_setDirty and UIManager and UIManager.setDirty then
        orig_setDirty = UIManager.setDirty
        UIManager.setDirty = function(self_ui, widget, mode, ...)
            if WaveformClamper.enabled then
                if WaveformClamper.scroll_pan_active and scroll_releasing and rescheduleScrollSettle then
                    rescheduleScrollSettle(0.15)
                end
                mode = WaveformClamper.clampMode(widget, mode)
            end
            return orig_setDirty(self_ui, widget, mode, ...)
        end
    end

    -- Install Screen hooks for refresh coalescing and multi-slice suppression
    RefreshCoalescer.installHooks()

    local p_android = getAndroidModule()
    if enabled then
        self:applyOptimalSettings()
    end

    -- Install hardware ARect + SurfaceFlinger Regal suppression Screen hooks
    self:installScreenHooks(p_android)

    -- Install continuous scroll pan/release hooks for smooth scroll -> Regal settle
    self:installScrollPanHooks()

    logger.info(string.format("[BooxRefreshManager] Initialized (enabled: %s, coalesce window: %dms, android: %s)",
        tostring(enabled), math.floor(RefreshCoalescer.coalesce_window_s * 1000), tostring(p_android ~= nil)))
end

local scroll_inertia_cb = nil
local scroll_dither_override_cb = nil

local function getScrollTime()
    local TimeVal = package.loaded["ui/time"]
    if not TimeVal then
        local ok_tv, tv = pcall(require, "ui/time")
        if ok_tv then TimeVal = tv end
    end
    if TimeVal and TimeVal.now then
        local t = TimeVal:now()
        if type(t) == "number" then
            if TimeVal.to_s then
                return TimeVal.to_s(t)
            end
            return t / 1000000
        elseif type(t) == "table" or type(t) == "cdata" then
            local ok_sec, sec = pcall(function() return t.sec end)
            if ok_sec and type(sec) == "number" then
                local ok_usec, usec = pcall(function() return t.usec end)
                return sec + ((ok_usec and type(usec) == "number" and usec) or 0) / 1000000
            end
        end
    end
    return os.clock()
end

cancelDitherOverrideTimer = function()
    if UIManager and UIManager.unschedule and scroll_dither_override_cb then
        pcall(function() UIManager:unschedule(scroll_dither_override_cb) end)
    end
    scroll_dither_override_cb = nil
end

local function cancelScrollTimers()
    if UIManager and UIManager.unschedule then
        if scroll_settle_cb then
            pcall(function() UIManager:unschedule(scroll_settle_cb) end)
        end
        if scroll_fallback_cb then
            pcall(function() UIManager:unschedule(scroll_fallback_cb) end)
        end
        if scroll_inertia_cb then
            pcall(function() UIManager:unschedule(scroll_inertia_cb) end)
        end
    end
    scroll_settle_cb = nil
    scroll_fallback_cb = nil
    scroll_inertia_cb = nil
end

local function restoreReaderPagingPanRates(rp)
    if not rp then return end
    rp._brm_last_rel = nil
    rp._brm_last_origin = nil
    rp._brm_vel_y = nil
    rp._brm_last_pan_t = nil
    if rp._brm_orig_pan_rate ~= nil then
        rp.pan_rate = rp._brm_orig_pan_rate
        rp._brm_orig_pan_rate = nil
    end
    if rp._brm_orig_pan_interval ~= nil then
        rp.pan_interval = rp._brm_orig_pan_interval
        rp._brm_orig_pan_interval = nil
    end
    if rp._brm_orig_scroll_activation_delay ~= nil then
        rp.scroll_activation_delay = rp._brm_orig_scroll_activation_delay
        rp._brm_orig_scroll_activation_delay = nil
    end
end

clearContinuousScrollState = function()
    cancelScrollTimers()
    cancelDitherOverrideTimer()
    scroll_releasing = false
    if active_scroll_rp then
        restoreReaderPagingPanRates(active_scroll_rp)
    end
    WaveformClamper.scroll_pan_active = false
    scroll_sf_disarmed = false
    scroll_oec_smooth_active = false
    scroll_app_scope_dirty = false
    active_scroll_view = nil
    active_scroll_rp = nil
end

local function settleScrollToRegal()
    cancelScrollTimers()
    scroll_releasing = false
    restoreReaderPagingPanRates(active_scroll_rp)
    active_scroll_rp = nil
    if WaveformClamper.enabled
        and WaveformClamper.isReaderDocumentView()
        and active_scroll_view and active_scroll_view.page_scroll
    then
        -- Stay in fast Smooth scroll; re-arm per-gesture ViewUpdateHelper assertion without re-calling OEC
        scroll_sf_disarmed = false
        return
    end
    WaveformClamper.scroll_pan_active = false
    scroll_sf_disarmed = false
    scroll_oec_smooth_active = false
    scroll_app_scope_dirty = false
    active_scroll_view = nil
end

rescheduleScrollSettle = function(delay_s)
    if UIManager and UIManager.unschedule and scroll_settle_cb then
        pcall(function() UIManager:unschedule(scroll_settle_cb) end)
    end
    scroll_settle_cb = nil
    if UIManager and UIManager.scheduleIn then
        scroll_settle_cb = function()
            scroll_settle_cb = nil
            settleScrollToRegal()
        end
        UIManager:scheduleIn(delay_s or 0.15, scroll_settle_cb)
    else
        settleScrollToRegal()
    end
end

local function recordPanVelocity(rp, dy, now_t)
    if not rp then return end
    if dy ~= 0 then
        if rp._brm_last_pan_t then
            local dt = now_t - rp._brm_last_pan_t
            if dt >= 0.004 and dt <= 0.18 then
                local inst_v = math.max(-6000, math.min(6000, dy / dt))
                rp._brm_vel_y = (rp._brm_vel_y or inst_v) * 0.4 + inst_v * 0.6
            elseif dt > 0.18 then
                rp._brm_vel_y = 0
            end
        end
        rp._brm_last_pan_t = now_t
    end
end

local function startScrollInertialCoast(rp, fallback_ges, is_swipe)
    local vy = (rp and rp._brm_vel_y) or 0
    local last_t = rp and rp._brm_last_pan_t
    if rp then
        rp._brm_vel_y = nil
        rp._brm_last_pan_t = nil
    end
    -- If inertia is already running (e.g. trailing onSwipe after onPanRelease), do not cancel it
    if is_swipe and scroll_inertia_cb ~= nil and math.abs(vy) < 100 then
        return
    end
    if math.abs(vy) < 100 and fallback_ges then
        local rel_y = fallback_ges.relative and fallback_ges.relative.y
        if rel_y and rel_y ~= 0 then
            vy = math.max(-6000, math.min(6000, rel_y * 6))
        elseif fallback_ges.distance and fallback_ges.distance > 0 then
            local dir = fallback_ges.direction
            if dir == "north" then
                vy = -math.min(6000, fallback_ges.distance * 4)
            elseif dir == "south" then
                vy = math.min(6000, fallback_ges.distance * 4)
            end
        end
    end
    if not rp or not rp.view or not rp.view.page_scroll
        or not UIManager or not UIManager.scheduleIn
        or math.abs(vy) < 100
        or (last_t and (getScrollTime() - last_t) > 0.18)
    then
        scroll_releasing = true
        rescheduleScrollSettle(0.15)
        return
    end
    if scroll_inertia_cb ~= nil and UIManager and UIManager.unschedule then
        pcall(function() UIManager:unschedule(scroll_inertia_cb) end)
        scroll_inertia_cb = nil
    end

    scroll_releasing = false
    local function tick()
        scroll_inertia_cb = nil
        local ok_tick, err_tick = xpcall(function()
            if not WaveformClamper.enabled or not WaveformClamper.scroll_pan_active
                or not rp.view or not rp.view.page_scroll
                or not WaveformClamper.isReaderDocumentView()
            then
                scroll_releasing = true
                rescheduleScrollSettle(0.15)
                return
            end
            local step_dy = vy * 0.026
            vy = vy * 0.88
            if math.abs(step_dy) < 1.2 then
                scroll_releasing = true
                rescheduleScrollSettle(0.15)
                return
            end
            if rp.onScrollPanRel then
                pcall(rp.onScrollPanRel, rp, -step_dy)
            elseif rp.view and rp.view.PanningUpdate then
                pcall(rp.view.PanningUpdate, rp.view, 0, step_dy)
            end
            if UIManager and UIManager.setDirty then
                UIManager:setDirty(rp.view, "ui")
            end
            scroll_inertia_cb = tick
            UIManager:scheduleIn(0.026, scroll_inertia_cb)
        end, debug.traceback)
        if not ok_tick then
            logger.err("[BooxRefreshManager] inertial tick error: " .. tostring(err_tick))
            scroll_releasing = true
            rescheduleScrollSettle(0.15)
        end
    end
    scroll_inertia_cb = tick
    UIManager:scheduleIn(0.026, scroll_inertia_cb)
end

function BooxRefreshManager:installScrollPanHooks()
    local ok_rp, ReaderPaging = pcall(require, "apps/reader/modules/readerpaging")
    if not ok_rp or not ReaderPaging then
        return
    end

    local function runScrollHookSafely(hook_name, fn, fallback_fn, self_rp, arg, ges)
        local ok, res = xpcall(function()
            return fn(self_rp, arg, ges)
        end, debug.traceback)
        if not ok then
            logger.err(string.format("[BooxRefreshManager] %s error: %s", hook_name, tostring(res)))
            if fallback_fn then
                return fallback_fn(self_rp, arg, ges)
            end
            return true
        end
        return res
    end

    if ReaderPaging.onPan and not orig_reader_paging_onPan then
        orig_reader_paging_onPan = ReaderPaging.onPan
        ReaderPaging.onPan = function(self_rp, arg, ges)
            return runScrollHookSafely("ReaderPaging.onPan", function(rp, a, g)
            if WaveformClamper.enabled
                and rp and rp.view and rp.view.page_scroll
                and WaveformClamper.isReaderDocumentView()
            then
                cancelScrollTimers()
                scroll_releasing = false
                if not WaveformClamper.scroll_pan_active or not scroll_sf_disarmed then
                    local epd_mode = WaveformClamper.scroll_epd_mode or 2
                    local active_android = getAndroidModule()
                    if active_android then
                        if not scroll_oec_smooth_active or scroll_app_scope_dirty then
                            BooxRefreshManager:applyOECAppConfig(active_android, SMOOTH_APP_CONFIG_JSON, false)
                            scroll_oec_smooth_active = true
                            scroll_app_scope_dirty = false
                            -- oec_service asynchronously enables dither (~10ms after applyAppConfig); override it back to 0 at 0.05s for 38 Hz
                            if UIManager and UIManager.scheduleIn then
                                cancelDitherOverrideTimer()
                                scroll_dither_override_cb = function()
                                    scroll_dither_override_cb = nil
                                    if WaveformClamper.scroll_pan_active then
                                        local a_mod = getAndroidModule()
                                        if a_mod then
                                            withViewUpdateHelper(a_mod, function(env, ffi_mod, vuh_cls)
                                                disarmSurfaceFlingerRegal(env, ffi_mod, vuh_cls, epd_mode, 0, false, 7, true)
                                            end)
                                        end
                                    end
                                end
                                UIManager:scheduleIn(0.05, scroll_dither_override_cb)
                            end
                        end
                        withViewUpdateHelper(active_android, function(env, ffi_mod, vuh_cls)
                            disarmSurfaceFlingerRegal(env, ffi_mod, vuh_cls, epd_mode, 0, false, 7, true)
                        end)
                    end
                    scroll_sf_disarmed = true
                    logger.info(string.format("[BooxRefreshManager] Continuous scroll pan started -> Smooth OEC + disarmed Regal (epd_mode=%d, antiFlicker=0, dither=false, turbo=7)", epd_mode))
                end
                WaveformClamper.scroll_pan_active = true
                active_scroll_view = rp.view
                active_scroll_rp = rp
                if rp._brm_orig_pan_rate == nil then
                    rp._brm_orig_pan_rate = rp.pan_rate
                    rp._brm_orig_pan_interval = rp.pan_interval
                    rp._brm_orig_scroll_activation_delay = rp.scroll_activation_delay
                end
                rp.pan_rate = 60
                rp.pan_interval = 16666
                rp.scroll_activation_delay = 0
                if UIManager and UIManager.scheduleIn then
                    scroll_fallback_cb = function()
                        scroll_fallback_cb = nil
                        settleScrollToRegal()
                    end
                    UIManager:scheduleIn(2.5, scroll_fallback_cb)
                end
                local rel = g and g.relative
                if rel and (rel.x or rel.y) then
                    local rx = rel.x or 0
                    local ry = rel.y or 0
                    local now_t = getScrollTime()
                    if g and g.pos and (g.pos.x or g.pos.y) then
                        local ox = (g.pos.x or 0) - rx
                        local oy = (g.pos.y or 0) - ry
                        if rp._brm_last_origin then
                            if math.abs(ox - rp._brm_last_origin.x) > 2
                                or math.abs(oy - rp._brm_last_origin.y) > 2
                            then
                                rp._brm_last_rel = { x = 0, y = 0 }
                                rp._brm_vel_y = 0
                                rp._brm_last_pan_t = now_t
                            end
                        end
                        rp._brm_last_origin = { x = ox, y = oy }
                    end
                    if not rp._brm_last_rel then
                        rp._brm_last_rel = { x = 0, y = 0 }
                        rp._brm_vel_y = 0
                        rp._brm_last_pan_t = now_t
                    end
                    local dx = rx - rp._brm_last_rel.x
                    local dy = ry - rp._brm_last_rel.y
                    rp._brm_last_rel.x = rx
                    rp._brm_last_rel.y = ry
                    if dy ~= 0 then
                        recordPanVelocity(rp, dy, now_t)
                        if rp.onScrollPanRel then
                            pcall(rp.onScrollPanRel, rp, -dy)
                        elseif rp.view and rp.view.PanningUpdate then
                            pcall(rp.view.PanningUpdate, rp.view, dx, dy)
                        end
                        if UIManager and UIManager.setDirty then
                            UIManager:setDirty(rp.view, "ui")
                        end
                    elseif dx ~= 0 and rp.view and rp.view.PanningUpdate then
                        pcall(rp.view.PanningUpdate, rp.view, dx, 0)
                        if UIManager and UIManager.setDirty then
                            UIManager:setDirty(rp.view, "ui")
                        end
                    end
                end
                return true
            end
            if rp and rp.view and not rp.view.page_scroll
                and (WaveformClamper.scroll_pan_active or isContinuousScrollSession() or scroll_oec_smooth_active)
                and clearContinuousScrollState
            then
                clearContinuousScrollState()
            end
            return orig_reader_paging_onPan(rp, a, g)
            end, orig_reader_paging_onPan, self_rp, arg, ges)
        end
    end

    if ReaderPaging.onPanRelease and not orig_reader_paging_onPanRelease then
        orig_reader_paging_onPanRelease = ReaderPaging.onPanRelease
        ReaderPaging.onPanRelease = function(self_rp, arg, ges)
            return runScrollHookSafely("ReaderPaging.onPanRelease", function(rp, a, g)
            if WaveformClamper.enabled
                and rp and rp.view and rp.view.page_scroll
                and WaveformClamper.isReaderDocumentView()
            then
                if WaveformClamper.scroll_pan_active and rp._brm_last_rel then
                    local rel = g and g.relative
                    if rel and (rel.x or rel.y) then
                        local dx = (rel.x or 0) - rp._brm_last_rel.x
                        local dy = (rel.y or 0) - rp._brm_last_rel.y
                        if dy ~= 0 then
                            recordPanVelocity(rp, dy, getScrollTime())
                            if rp.onScrollPanRel then
                                pcall(rp.onScrollPanRel, rp, -dy)
                            elseif rp.view and rp.view.PanningUpdate then
                                pcall(rp.view.PanningUpdate, rp.view, dx, dy)
                            end
                            if UIManager and UIManager.setDirty then
                                UIManager:setDirty(rp.view, "ui")
                            end
                        elseif dx ~= 0 and rp.view and rp.view.PanningUpdate then
                            pcall(rp.view.PanningUpdate, rp.view, dx, 0)
                            if UIManager and UIManager.setDirty then
                                UIManager:setDirty(rp.view, "ui")
                            end
                        end
                    end
                end
                rp._brm_last_rel = nil
                rp._brm_last_origin = nil
                startScrollInertialCoast(rp, g)
                return true
            end
            return orig_reader_paging_onPanRelease(rp, a, g)
            end, orig_reader_paging_onPanRelease, self_rp, arg, ges)
        end
    end

    if ReaderPaging.onSwipe and not orig_reader_paging_onSwipe then
        orig_reader_paging_onSwipe = ReaderPaging.onSwipe
        ReaderPaging.onSwipe = function(self_rp, arg, ges)
            return runScrollHookSafely("ReaderPaging.onSwipe", function(rp, a, g)
            if WaveformClamper.enabled
                and rp and rp.view and rp.view.page_scroll
                and WaveformClamper.isReaderDocumentView()
            then
                rp._brm_last_rel = nil
                rp._brm_last_origin = nil
                if WaveformClamper.scroll_pan_active then
                    startScrollInertialCoast(rp, g, true)
                end
                return true
            end
            return orig_reader_paging_onSwipe(rp, a, g)
            end, orig_reader_paging_onSwipe, self_rp, arg, ges)
        end
    end
end

function BooxRefreshManager:onSuspend()
    cancelScrollTimers()
    cancelDitherOverrideTimer()
    restoreReaderPagingPanRates(active_scroll_rp)
    active_scroll_rp = nil
    WaveformClamper.scroll_pan_active = false
    scroll_sf_disarmed = false
    scroll_oec_smooth_active = false
    scroll_app_scope_dirty = false
    scroll_releasing = false
    active_scroll_view = nil
    RefreshCoalescer.flush()
    RefreshCoalescer.cancel()
end

function BooxRefreshManager:onPause()
    cancelScrollTimers()
    cancelDitherOverrideTimer()
    restoreReaderPagingPanRates(active_scroll_rp)
    active_scroll_rp = nil
    WaveformClamper.scroll_pan_active = false
    scroll_sf_disarmed = false
    scroll_oec_smooth_active = false
    scroll_app_scope_dirty = false
    scroll_releasing = false
    active_scroll_view = nil
    RefreshCoalescer.flush()
    RefreshCoalescer.cancel()
end

function BooxRefreshManager:onResume()
    -- Intentionally no JNI calls during APP_CMD_RESUME to keep JVM thread state clean.
end

function BooxRefreshManager:onDestroy()
    cancelScrollTimers()
    cancelDitherOverrideTimer()
    restoreReaderPagingPanRates(active_scroll_rp)
    active_scroll_rp = nil
    WaveformClamper.scroll_pan_active = false
    scroll_sf_disarmed = false
    scroll_oec_smooth_active = false
    scroll_app_scope_dirty = false
    scroll_releasing = false
    active_scroll_view = nil
    local ok_rp, ReaderPaging = pcall(require, "apps/reader/modules/readerpaging")
    if ok_rp and ReaderPaging then
        if orig_reader_paging_onPan then
            ReaderPaging.onPan = orig_reader_paging_onPan
            orig_reader_paging_onPan = nil
        end
        if orig_reader_paging_onPanRelease then
            ReaderPaging.onPanRelease = orig_reader_paging_onPanRelease
            orig_reader_paging_onPanRelease = nil
        end
        if orig_reader_paging_onSwipe then
            ReaderPaging.onSwipe = orig_reader_paging_onSwipe
            orig_reader_paging_onSwipe = nil
        end
    end
    RefreshCoalescer.removeHooks()
    if orig_setDirty and UIManager then
        UIManager.setDirty = orig_setDirty
        orig_setDirty = nil
    end
    if orig_ui_imp and Screen then
        Screen.refreshUIImp = orig_ui_imp
        orig_ui_imp = nil
    end
    if orig_fast_imp and Screen then
        Screen.refreshFastImp = orig_fast_imp
        orig_fast_imp = nil
    end
    if orig_partial_imp and Screen then
        Screen.refreshPartialImp = orig_partial_imp
        orig_partial_imp = nil
    end
    if orig_full_imp and Screen then
        Screen.refreshFullImp = orig_full_imp
        orig_full_imp = nil
    end
end

function BooxRefreshManager:addToMainMenu(menu_items)
    menu_items.boox_refresh_manager = {
        text = _("Boox Refresh Manager"),
        sorting_hint = "device",
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = _("Regal Mode Flash Suppression"),
                    help_text = _("Suppresses full-screen white flashes when navigating menus and Bookshelf in Regal mode, while preserving full color fidelity and crisp Regal page turns."),
                    checked_func = function()
                        return WaveformClamper.enabled
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local new_val = not WaveformClamper.enabled
                        WaveformClamper.enabled = new_val
                        RefreshCoalescer.enabled = new_val
                        if G_reader_settings and G_reader_settings.saveSetting then
                            G_reader_settings:saveSetting("boox_refresh_manager_enabled", new_val)
                            pcall(function() G_reader_settings:flush() end)
                        end
                        if new_val and BooxRefreshManager.instance then
                            BooxRefreshManager.instance:applyOptimalSettings()
                        end
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = _("Reader Regal Mode"),
                    help_text = _("Choose which Boox Regal profile is applied for in-book reading (Regal Plus [updateMode 5] is the default; Regal [updateMode 3] disables the SurfaceFlinger debouncer)."),
                    keep_menu_open = true,
                    sub_item_table_func = function()
                        local function selectReaderRegalMode(mode, touchmenu_instance)
                            if G_reader_settings and G_reader_settings.saveSetting then
                                G_reader_settings:saveSetting("boox_refresh_manager_reader_regal_mode", mode)
                                pcall(function() G_reader_settings:flush() end)
                            end
                            local mgr = BooxRefreshManager.instance or self
                            if WaveformClamper.enabled and mgr and mgr.applyOptimalSettings then
                                mgr:applyOptimalSettings()
                            end
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end
                        return {
                            {
                                text = _("Regal Plus (Default)"),
                                help_text = _("Uses Boox UPDATE_MODE_REGAL_PLUS (updateMode 5) with SurfaceFlinger debouncer enabled for in-book reading."),
                                radio = true,
                                checked_func = function()
                                    return getReaderRegalMode() == "regal_plus"
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    selectReaderRegalMode("regal_plus", touchmenu_instance)
                                end,
                            },
                            {
                                text = _("Regal"),
                                help_text = _("Uses Boox UPDATE_MODE_REGAL (updateMode 3) without the SurfaceFlinger debouncer for in-book reading."),
                                radio = true,
                                checked_func = function()
                                    return getReaderRegalMode() == "regal"
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    selectReaderRegalMode("regal", touchmenu_instance)
                                end,
                            },
                        }
                    end,
                },
                {
                    text = _("Restore Optimal Boox Settings"),
                    help_text = _("Restores all optimal Boox and KOReader settings: Regal Flash Suppression, SurfaceFlinger Display Scheme 4, Anti-Flicker 10, Boox E-Ink Center Regal profile, and Avoid Flashing UI."),
                    keep_menu_open = false,
                    callback = function()
                        if BooxRefreshManager.instance then
                            BooxRefreshManager.instance:applyOptimalSettings()
                        else
                            self:applyOptimalSettings()
                        end
                        local mode = getReaderRegalMode()
                        local mode_desc = (mode == "regal") and "Regal (updateMode 3)" or "Regal Plus (updateMode 5)"
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Optimal Boox settings restored:\n- Regal Flash Suppression: Enabled\n- SurfaceFlinger Scheme: 4 (Animation) / Anti-Flicker 10\n- Hardware ARect + App-Scope EPD Override: Active\n- Boox E-Ink Center Profile: %s\n- Avoid Flashing UI: Enabled"), mode_desc),
                            timeout = 8,
                        })
                    end,
                },
                {
                    text = _("Settings & Status Diagnostics"),
                    help_text = _("Displays current state of flash suppression, coalesce window, hardware bridge availability, and KOReader avoid_flashing_ui setting."),
                    keep_menu_open = false,
                    callback = function()
                        local avoid_flash = false
                        if G_reader_settings and G_reader_settings.isTrue then
                            avoid_flash = G_reader_settings:isTrue("avoid_flashing_ui")
                        end
                        local p_android = getAndroidModule()
                        local has_jni = p_android and p_android.app and p_android.app.activity and p_android.app.activity.vm ~= nil
                        local status_text = string.format(
                            "Device: NoteAir5C (Color E-Ink)\nRegal Flash Suppression: %s\nAvoid Flashing UI: %s\nCoalesce Window: %dms\nHardware JNI Bridge: %s\nScreen Hook Installed: %s\nReader Page Turns: Native Regal (Unclamped)",
                            WaveformClamper.enabled and "ACTIVE" or "DISABLED",
                            avoid_flash and "ENABLED" or "DISABLED",
                            math.floor(RefreshCoalescer.coalesce_window_s * 1000),
                            has_jni and "AVAILABLE" or "UNAVAILABLE",
                            (orig_ui_imp ~= nil) and "ACTIVE" or "INACTIVE"
                        )
                        UIManager:show(InfoMessage:new{
                            text = status_text,
                            timeout = 8,
                        })
                    end,
                },
            }
        end,
    }
end

BooxRefreshManager._withJNIEnv = withJNIEnv
BooxRefreshManager._OPTIMAL_REGAL_APP_CONFIG_JSON = OPTIMAL_REGAL_APP_CONFIG_JSON
BooxRefreshManager._buildRegalAppConfigJSON = buildRegalAppConfigJSON
BooxRefreshManager._getReaderRegalMode = getReaderRegalMode

return BooxRefreshManager
