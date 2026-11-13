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
local orig_partial_imp = nil
local orig_full_imp = nil

local JNI_OK = 0
local JNI_VERSION_1_6 = 0x00010006

local OPTIMAL_REGAL_APP_CONFIG_JSON = '{"activityConfigMap":{},"autoFreezeConfig":{"autoFreeze":true,"enable":true,"supportAutoFreeze":true},"autoStartConfig":{"autoStart":false,"enable":true,"supportAdjust":true},"colorConfigMap":{},"colorMode":"vivid","cssConfigMap":{},"dpiConfig":{"dpi":0,"enable":true},"enable":true,"extraConfig":{"allowSplashScreen":true,"enable":true,"forceFullScreen":false,"fullPMAccess":false,"fullPMAccessTimeout":300000,"useDialogBorder":false,"usePageKeyAsVolumeKey":true},"forceScrollRefreshClsList":["com.qmuiteam.qmui.arch.SwipeBackLayout","mozilla.components.browser.engine.gecko.GeckoEngineView$geckoView$1","com.dragon.reader.simple.slip.OverScrollView","com.dragon.read.reader.ui.ReaderOverScrollView"],"globalActivityConfig":{"clsName":"","disableScrollAnim":false,"displayConfig":{"bwMode":0,"cfaColorBrightness":0,"cfaColorSaturation":0,"cfaColorSaturationMin":60,"contrast":30,"ditherThreshold":128,"enable":true,"enhance":true,"monoLevel":0},"eacScrollStyle":2,"enable":false,"noteConfig":{"compatibleVersionCode":0,"enable":false,"globalStrokeStyle":{"enable":false,"strokeColor":-16777216,"strokeExtraArgs":[],"strokeParams":[],"strokeStyle":0,"strokeWidth":3},"repaintLatency":500,"styleMap":{},"supportNoteConfig":false},"paintConfig":{"antiAlisingType":0,"ditherBitmap":false,"enable":true,"fillBrightness":0,"fillContrast":0,"fillEAC":false,"iconBrightness":0,"iconContrast":0,"iconEAC":false,"iconThreshold":0,"imgEAC":false,"imgGamma":60,"quantBits":3,"textBold":false,"textEACType":0},"refreshConfig":{"animationDuration":0,"antiFlicker":0,"enable":true,"gcInterval":20,"refreshModeAlias":"regal_plus","refreshModeIndex":"refresh_mode_1","supportRegal":true,"turbo":0,"updateMode":2,"useGCForNewSurface":false},"scrollRefreshDelay":1000},"globalCSSConfig":{"clsName":"","customCSS":"","enable":true,"fontBold":false,"fontColor":0,"fontSize":100},"keyboardConfig":{"enable":true,"pageKeyMode":1},"networkConfig":{"enable":true,"overrideRules":0},"pkgName":"org.koreader.launcher","rotationConfig":{"enable":true,"overrideRotation":-1},"scrollArgs":{"duration":600,"endXPercent":0.5,"endYPercent":0.8,"sampleTime":16,"startXPercent":0.5,"startYPercent":0.2},"scrollViewWhiteList":[],"supportEAC":false}'

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

-- Re-entrant-safe JNI helper: avoids detaching an already-attached JVM thread
-- and clears any pending Java exception so ART never aborts on return.
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

    local ok, res = pcall(fn, env, ffi)
    clearJNIException(env)
    if attached_here then
        jvm[0].DetachCurrentThread(jvm)
    end
    if not ok and logger and logger.warn then
        logger.warn("[BooxRefreshManager] JNI error: " .. tostring(res))
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
local function disarmSurfaceFlingerRegal(env, ffi_mod, vuh_cls, epd_mode)
    local target_epd_mode = epd_mode or WaveformClamper.ui_epd_mode or 5

    callStaticVUHBooleanMethod(env, vuh_cls, "setDisplayScheme", "(I)Z", ffi_mod.cast("jint", 4))
    callStaticVUHMethod(env, vuh_cls, "antiFlicker", "(I)V", ffi_mod.cast("jint", 10))
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
    callStaticVUHMethod(env, vuh_cls, "enableDither", "(Z)V", ffi_mod.cast("jboolean", 0))

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
local function armSurfaceFlingerRegalForReader(env, ffi_mod, vuh_cls)
    callStaticVUHMethod(env, vuh_cls, "byPass", "(I)V", ffi_mod.cast("jint", 0))
    for _, clear_flag in ipairs({ 0, 1, 2 }) do
        callStaticVUHMethod(env, vuh_cls, "clearAppScopeUpdate", "(I)V", ffi_mod.cast("jint", clear_flag))
    end
    callStaticVUHBooleanMethod(env, vuh_cls, "setDisplayScheme", "(I)Z", ffi_mod.cast("jint", 1))
    callStaticVUHMethod(env, vuh_cls, "antiFlicker", "(I)V", ffi_mod.cast("jint", 0))
    callStaticVUHMethod(env, vuh_cls, "enableRegal", "(Z)V", ffi_mod.cast("jboolean", 1))
    callStaticVUHMethod(env, vuh_cls, "enableDither", "(Z)V", ffi_mod.cast("jboolean", 1))
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

function BooxRefreshManager:applyOECAppConfig(p_android, json_str)
    json_str = json_str or OPTIMAL_REGAL_APP_CONFIG_JSON
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
                        env[0].CallVoidMethod(env, bundle_obj, bundle_put_bool, save_key, ffi.cast("jboolean", 1))
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
    -- 1. Ensure KOReader avoid_flashing_ui setting and plugin enable flag are active
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting("avoid_flashing_ui", true)
        G_reader_settings:saveSetting("boox_refresh_manager_enabled", true)
        pcall(function() G_reader_settings:flush() end)
    end

    WaveformClamper.enabled = true
    RefreshCoalescer.enabled = true

    -- 2. Apply Boox OS E-Ink Center config first, then SurfaceFlinger display scheme / app-scope override
    local p_android = getAndroidModule()
    if p_android then
        self:applyOECAppConfig(p_android, OPTIMAL_REGAL_APP_CONFIG_JSON)
        self:applyHardwareDisplayScheme(p_android)
    end
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

        if WaveformClamper.isReaderDocumentView() then
            local active_android = p_android or getAndroidModule()
            withViewUpdateHelper(active_android, function(env, ffi_mod, vuh_cls)
                armSurfaceFlingerRegalForReader(env, ffi_mod, vuh_cls)
                logger.info("[BooxRefreshManager] refreshUIImp armed SurfaceFlinger Regal for Reader: byPass(0), clearAppScopeUpdate(0..2), enableRegal(true), enableDither(false)")
            end)
            return orig_ui_imp(self_scr, x, y, w, h)
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

            local ok_ffi, ffi = pcall(require, "ffi")
            if ok_ffi and ffi and active_android and active_android.app and active_android.app.window and active_android.lib then
                local buffer = ffi.new("ANativeWindow_Buffer[1]")
                local dirty_rect = nil
                if rx and ry and rw and rh and rw > 0 and rh > 0 and (rw < 2480 or rh < 1860) then
                    dirty_rect = ffi.new("ARect", { left = rx, top = ry, right = rx + rw, bottom = ry + rh })
                end

                if active_android.lib.ANativeWindow_lock(active_android.app.window, buffer, dirty_rect) == 0 then
                    local ok_bb, BB = pcall(require, "ffi/blitbuffer")
                    if ok_bb and BB then
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

                    -- Disarm SurfaceFlinger debouncer/Regal and apply app-scope EPD mode before posting the buffer
                    withViewUpdateHelper(active_android, function(env, ffi_mod, vuh_cls)
                        disarmSurfaceFlingerRegal(env, ffi_mod, vuh_cls)
                        logger.info("[BooxRefreshManager] Disarmed SurfaceFlinger Regal: byPass(0), debouncer(false), enableRegal(false), enableDither(false), applyAppScopeUpdate")
                    end)

                    active_android.lib.ANativeWindow_unlockAndPost(active_android.app.window)
                    logger.info(string.format("[BooxRefreshManager] ANativeWindow_lock with ARect: %d,%d to %d,%d",
                        rx, ry, rx + rw, ry + rh))
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
            local active_android = p_android or getAndroidModule()
            withViewUpdateHelper(active_android, function(env, ffi_mod, vuh_cls)
                armSurfaceFlingerRegalForReader(env, ffi_mod, vuh_cls)
                logger.info(string.format("[BooxRefreshManager] %s armed SurfaceFlinger Regal for Reader: byPass(0), clearAppScopeUpdate(0..2), enableRegal(true), enableDither(false)", method_name))
            end)
            return orig_imp(self_scr, x, y, w, h)
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

    logger.info(string.format("[BooxRefreshManager] Initialized (enabled: %s, coalesce window: %dms, android: %s)",
        tostring(enabled), math.floor(RefreshCoalescer.coalesce_window_s * 1000), tostring(p_android ~= nil)))
end

function BooxRefreshManager:onSuspend()
    RefreshCoalescer.flush()
    RefreshCoalescer.cancel()
end

function BooxRefreshManager:onPause()
    RefreshCoalescer.flush()
    RefreshCoalescer.cancel()
end

function BooxRefreshManager:onResume()
    -- Intentionally no JNI calls during APP_CMD_RESUME to keep JVM thread state clean.
end

function BooxRefreshManager:onDestroy()
    RefreshCoalescer.removeHooks()
    if orig_setDirty and UIManager then
        UIManager.setDirty = orig_setDirty
        orig_setDirty = nil
    end
    if orig_ui_imp and Screen then
        Screen.refreshUIImp = orig_ui_imp
        orig_ui_imp = nil
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
                    text = _("Restore Optimal Boox Settings"),
                    help_text = _("Restores all optimal Boox and KOReader settings: Regal Flash Suppression, SurfaceFlinger Display Scheme 4, Anti-Flicker 10, Boox E-Ink Center Regal profile, and Avoid Flashing UI."),
                    keep_menu_open = false,
                    callback = function()
                        if BooxRefreshManager.instance then
                            BooxRefreshManager.instance:applyOptimalSettings()
                        else
                            self:applyOptimalSettings()
                        end
                        UIManager:show(InfoMessage:new{
                            text = _("Optimal Boox settings restored:\n- Regal Flash Suppression: Enabled\n- SurfaceFlinger Scheme: 4 (Animation) / Anti-Flicker 10\n- Hardware ARect + App-Scope EPD Override: Active\n- Boox E-Ink Center Profile: Regal Plus (updateMode 2)\n- Avoid Flashing UI: Enabled"),
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

return BooxRefreshManager
